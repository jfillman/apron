// The tenant-onboarding ApplicationSets that apron renders with clearance.gate.agent.gatedSet, run by the real Argo CD
// ApplicationSet controller (github.com/argoproj/argo-cd/v3, the version argocd-apps runs) against a real kube-apiserver
// (envtest). The git generator is Argo CD's own; only the repo-server behind it is replaced by an in-memory tenants repo,
// so identity.yaml files are parsed, flattened and selected exactly as on a cluster. No Argo CD application controller runs:
// an Application deleted with the resources finalizer keeps a deletionTimestamp, which is how a cascade is seen here.
//
//	APRON_GATED_RENDER=<apron render with gatedSet> APRON_GATED_HANDOVER_RENDER=<the same with gatedSetHandover> \
//	KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) go test ./...
//
// tests/run.sh sets all three. Without them the test skips, unless APRON_REQUIRE_ENVTEST=1 (CI), where it fails.
package appset

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-logr/logr"
	log "github.com/sirupsen/logrus"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/client-go/kubernetes"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/yaml"

	"github.com/argoproj/argo-cd/v3/applicationset/controllers"
	"github.com/argoproj/argo-cd/v3/applicationset/generators"
	appsetmetrics "github.com/argoproj/argo-cd/v3/applicationset/metrics"
	"github.com/argoproj/argo-cd/v3/applicationset/utils"
	"github.com/argoproj/argo-cd/v3/common"
	argov1alpha1 "github.com/argoproj/argo-cd/v3/pkg/apis/application/v1alpha1"
	"github.com/argoproj/argo-cd/v3/util/db"
	"github.com/argoproj/argo-cd/v3/util/settings"
)

const (
	ns        = "argocd-apps"
	tenantSet = "tenant-onboarding"
	gatedSet  = "tenant-onboarding-gated"
	finalizer = "resources-finalizer.argocd.argoproj.io"
	protect   = "clearance.hangar.io/protect"
	switched  = "clearance.hangar.io/switched"
)

// tenantsRepo stands in for the repo-server: the git generator asks it for the files matching a glob.
type tenantsRepo struct {
	mu    sync.Mutex
	files map[string]string
}

func (r *tenantsRepo) set(p, content string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.files[p] = content
}

func (r *tenantsRepo) GetFiles(_ context.Context, _, _, _, pattern string, _ bool, _ *argov1alpha1.SourceIntegrity) (map[string][]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string][]byte{}
	for p, c := range r.files {
		if ok, err := path.Match(pattern, p); err != nil {
			return nil, err
		} else if ok {
			out[p] = []byte(c)
		}
	}
	return out, nil
}

func (r *tenantsRepo) GetDirectories(context.Context, string, string, string, bool, *argov1alpha1.SourceIntegrity) ([]string, error) {
	return nil, nil
}

func identity(app, env, extra string) string {
	return fmt.Sprintf("appName: %s\ngitopsRepoUrl: https://example.test/gitops-%s\ngithubOwner: example\nenv: %s\n%s", app, app, env, extra)
}

// setsFrom turns an apron render's tenant-onboarding chart into the ApplicationSets Helm would apply: the chart's
// templates/render.yaml substitutes the cluster's defaults (fixed test values here), then emits the template once per set
// with that set's literal replacements, which are read from the rendered render.yaml itself.
func setsFrom(t *testing.T, renderDir string) map[string]*argov1alpha1.ApplicationSet {
	t.Helper()
	chart := filepath.Join(renderDir, "02-argocd-apps", "tenant-onboarding", "chart")
	tmpl, err := os.ReadFile(filepath.Join(chart, "applicationset.tmpl.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	rj, err := os.ReadFile(filepath.Join(chart, "templates", "render.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	base := strings.NewReplacer(
		"__SERVICE_NAMESPACE_PATTERN__", "{type}-{app}-{env}",
		"__DESTINATION_NAMESPACE__", `{{ dig "type" "app" . }}-{{.appName}}-{{.env}}`,
		"__DEFAULT_CHART_REPO_URL__", chartRepo,
		"__DEFAULT_CHART_PATH__", "charts/airframe-application",
		"__DEFAULT_CHART_TARGET_REVISION__", "v1.0.0",
		"__OBS_NAMESPACE__", "",
		"__OBS_INSTRUMENTATION__", "",
	).Replace(string(tmpl))
	blocks := regexp.MustCompile(`(?s)\{\{ \$t\s*(.*?)\}\}`).FindAllStringSubmatch(string(rj), -1)
	if len(blocks) != 2 {
		t.Fatalf("render.yaml: want 2 per-set blocks, got %d (is gatedSet on in %s?)", len(blocks), renderDir)
	}
	pair := regexp.MustCompile(`\|\s*replace\s+"([^"]*)"\s+"([^"]*)"`)
	out := map[string]*argov1alpha1.ApplicationSet{}
	for _, b := range blocks {
		text := base
		for _, m := range pair.FindAllStringSubmatch(b[1], -1) {
			text = strings.ReplaceAll(text, m[1], m[2])
		}
		if strings.Contains(text, "__") && regexp.MustCompile(`__[A-Z_]+__`).MatchString(text) {
			t.Fatalf("placeholder left after substitution: %s", regexp.MustCompile(`__[A-Z_]+__`).FindString(text))
		}
		var as argov1alpha1.ApplicationSet
		if err := yaml.UnmarshalStrict([]byte(text), &as); err != nil {
			t.Fatalf("ApplicationSet does not parse: %v", err)
		}
		out[as.Name] = &as
	}
	if out[tenantSet] == nil || out[gatedSet] == nil {
		t.Fatalf("want %s and %s, got %v", tenantSet, gatedSet, out)
	}
	return out
}

func argoCRDs(t *testing.T) []*apiextensionsv1.CustomResourceDefinition {
	t.Helper()
	f, err := os.Open(filepath.Join("..", "..", "templates", "01-argocd-platform", "install.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	dec := utilyaml.NewYAMLOrJSONDecoder(f, 4096)
	var crds []*apiextensionsv1.CustomResourceDefinition
	for {
		var raw map[string]any
		if err := dec.Decode(&raw); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		if raw["kind"] != "CustomResourceDefinition" {
			continue
		}
		b, _ := json.Marshal(raw)
		var crd apiextensionsv1.CustomResourceDefinition
		if err := json.Unmarshal(b, &crd); err != nil {
			t.Fatal(err)
		}
		if crd.Spec.Group == "argoproj.io" {
			crds = append(crds, &crd)
		}
	}
	if len(crds) < 3 {
		t.Fatalf("install.yaml: want the Argo CD CRDs, got %d", len(crds))
	}
	return crds
}

type world struct {
	t     *testing.T
	ctx   context.Context
	c     client.Client
	repo  *tenantsRepo
	sets  map[string]*argov1alpha1.ApplicationSet
	hsets map[string]*argov1alpha1.ApplicationSet
}

func start(t *testing.T) *world {
	if os.Getenv("KUBEBUILDER_ASSETS") == "" || os.Getenv("APRON_GATED_RENDER") == "" || os.Getenv("APRON_GATED_HANDOVER_RENDER") == "" {
		if os.Getenv("APRON_REQUIRE_ENVTEST") == "1" {
			t.Fatal("APRON_REQUIRE_ENVTEST=1 but KUBEBUILDER_ASSETS, APRON_GATED_RENDER or APRON_GATED_HANDOVER_RENDER is unset")
		}
		t.Skip("set KUBEBUILDER_ASSETS, APRON_GATED_RENDER and APRON_GATED_HANDOVER_RENDER (tests/run.sh does)")
	}
	log.SetLevel(log.WarnLevel)
	ctrl.SetLogger(logr.Discard())
	w := &world{t: t, repo: &tenantsRepo{files: map[string]string{}}}
	w.sets = setsFrom(t, os.Getenv("APRON_GATED_RENDER"))
	w.hsets = setsFrom(t, os.Getenv("APRON_GATED_HANDOVER_RENDER"))

	env := &envtest.Environment{CRDs: argoCRDs(t), ErrorIfCRDPathMissing: true}
	cfg, err := env.Start()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = env.Stop() })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	w.ctx = ctx

	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = argov1alpha1.AddToScheme(scheme)
	w.c, err = client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		t.Fatal(err)
	}
	for _, o := range []client.Object{
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}},
		&corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "argocd-cm", Namespace: ns, Labels: map[string]string{"app.kubernetes.io/part-of": "argocd"}}},
		&corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "argocd-secret", Namespace: ns, Labels: map[string]string{"app.kubernetes.io/part-of": "argocd"}}},
	} {
		if err := w.c.Create(ctx, o); err != nil {
			t.Fatal(err)
		}
	}
	for _, app := range []string{"shop", "pay"} {
		p := &argov1alpha1.AppProject{ObjectMeta: metav1.ObjectMeta{Name: app, Namespace: ns},
			Spec: argov1alpha1.AppProjectSpec{SourceRepos: []string{"*"}, Destinations: []argov1alpha1.ApplicationDestination{{Server: "*", Namespace: "*"}}}}
		if err := w.c.Create(ctx, p); err != nil {
			t.Fatal(err)
		}
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"}, HealthProbeBindAddress: "0"})
	if err != nil {
		t.Fatal(err)
	}
	k8s := kubernetes.NewForConfigOrDie(cfg)
	argoDB := db.NewDB(ns, settings.NewSettingsManager(ctx, k8s, ns), k8s)
	informer, err := settings.NewClusterInformer(k8s, ns)
	if err != nil {
		t.Fatal(err)
	}
	go informer.Run(ctx.Done())
	r := &controllers.ApplicationSetReconciler{
		Generators:               map[string]generators.Generator{"Git": generators.NewGitGenerator(w.repo, ns)},
		Client:                   mgr.GetClient(),
		Scheme:                   mgr.GetScheme(),
		Recorder:                 mgr.GetEventRecorderFor("applicationset-controller"), //nolint:staticcheck // what the controller's own main uses
		Renderer:                 &utils.Render{},
		Policy:                   argov1alpha1.ApplicationsSyncPolicySync, // the controller's default (no applicationsetcontroller.policy) ...
		EnablePolicyOverride:     true,                                    // ... with the override on, as the default flags give it
		KubeClientset:            k8s,
		ArgoDB:                   argoDB,
		ArgoCDNamespace:          ns,
		ApplicationSetNamespaces: []string{ns},
		Metrics:                  appsetmetrics.NewFakeAppsetMetrics(),
		ClusterInformer:          informer,
	}
	if err := r.SetupWithManager(mgr, false, 1); err != nil {
		t.Fatal(err)
	}
	go func() { _ = mgr.Start(ctx) }()
	return w
}

// apply creates or replaces the ApplicationSet (as the tenant-onboarding Application's sync would) and asks for a refresh.
func (w *world) apply(as *argov1alpha1.ApplicationSet) {
	w.t.Helper()
	cur := &argov1alpha1.ApplicationSet{}
	err := w.c.Get(w.ctx, types.NamespacedName{Namespace: ns, Name: as.Name}, cur)
	want := as.DeepCopy()
	want.Namespace = ns
	if want.Annotations == nil {
		want.Annotations = map[string]string{}
	}
	want.Annotations[common.AnnotationApplicationSetRefresh] = "true"
	switch {
	case apierrors.IsNotFound(err):
		if err := w.c.Create(w.ctx, want); err != nil {
			w.t.Fatal(err)
		}
	case err != nil:
		w.t.Fatal(err)
	default:
		want.ResourceVersion = cur.ResourceVersion
		if err := w.c.Update(w.ctx, want); err != nil {
			w.t.Fatal(err)
		}
	}
}

// refresh makes both sets read the tenants repo again (a git webhook does the same on a cluster).
func (w *world) refresh() {
	w.t.Helper()
	for _, n := range []string{tenantSet, gatedSet} {
		p := []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:"true"}}}`, common.AnnotationApplicationSetRefresh))
		if err := w.c.Patch(w.ctx, &argov1alpha1.ApplicationSet{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: n}}, client.RawPatch(types.MergePatchType, p)); err != nil {
			w.t.Fatal(err)
		}
	}
}

func (w *world) app(name string) *argov1alpha1.Application {
	a := &argov1alpha1.Application{}
	if err := w.c.Get(w.ctx, types.NamespacedName{Namespace: ns, Name: name}, a); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		w.t.Fatal(err)
	}
	return a
}

func owner(a *argov1alpha1.Application) string {
	if o := metav1.GetControllerOf(a); o != nil {
		return o.Name
	}
	return ""
}

func has(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// eventually polls cond for up to 30 s; the controller reconciles within a second or two of a change.
func (w *world) eventually(what string, cond func() (bool, string)) {
	w.t.Helper()
	var last string
	for i := 0; i < 150; i++ {
		ok, why := cond()
		if ok {
			return
		}
		last = why
		time.Sleep(200 * time.Millisecond)
	}
	w.t.Fatalf("%s: not reached in 30s: %s", what, last)
}

// steady checks cond holds for the whole of d (several reconciles), to show the controller does NOT do something.
func (w *world) steady(what string, d time.Duration, cond func() (bool, string)) {
	w.t.Helper()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if ok, why := cond(); !ok {
			w.t.Fatalf("%s: %s", what, why)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (w *world) setCondition(set string) string {
	as := &argov1alpha1.ApplicationSet{}
	if err := w.c.Get(w.ctx, types.NamespacedName{Namespace: ns, Name: set}, as); err != nil {
		return err.Error()
	}
	var b bytes.Buffer
	for _, c := range as.Status.Conditions {
		if c.Type == argov1alpha1.ApplicationSetConditionErrorOccurred && c.Status == argov1alpha1.ApplicationSetConditionStatusTrue {
			b.WriteString(c.Message)
		}
	}
	return b.String()
}

// observed is the handover's "the window is in force" check (README "Gated environments", step 1): it sets the set's refresh
// annotation and waits for the controller to remove it. Only a reconcile that read the set WITH the annotation removes it (the
// RefreshRequired branch at the end of Reconcile, an Update at the resourceVersion that reconcile read: a reconcile that read
// an older version gets a conflict), and the workqueue never runs two reconciles of one set at once. So once the annotation is
// gone, every reconcile that read the set before the window opened, with its deleting sync policy, has finished.
func (w *world) observed(set string) {
	w.t.Helper()
	p := []byte(fmt.Sprintf(`{"metadata":{"annotations":{%q:"true"}}}`, common.AnnotationApplicationSetRefresh))
	if err := w.c.Patch(w.ctx, &argov1alpha1.ApplicationSet{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: set}}, client.RawPatch(types.MergePatchType, p)); err != nil {
		w.t.Fatal(err)
	}
	w.eventually(set+": a reconcile after the window opened", func() (bool, string) {
		as := &argov1alpha1.ApplicationSet{}
		if err := w.c.Get(w.ctx, types.NamespacedName{Namespace: ns, Name: set}, as); err != nil {
			return false, err.Error()
		}
		if as.Spec.SyncPolicy == nil || as.Spec.SyncPolicy.ApplicationsSync == nil || *as.Spec.SyncPolicy.ApplicationsSync != argov1alpha1.ApplicationsSyncPolicyCreateUpdate {
			return false, "the window is not on the set"
		}
		_, pending := as.Annotations[common.AnnotationApplicationSetRefresh]
		return !pending, "the refresh annotation is still on the set"
	})
}

// carrier is the source the Clearance agent builds its plugin source on: the first git source (clearance v0.54.0
// providers/argocd/agent/optin.go, carrier). It must be the app's gitops repository (see the template's comment).
func carrier(srcs argov1alpha1.ApplicationSources) string {
	for _, s := range srcs {
		if s.Chart == "" && s.RepoURL != "" && !strings.HasPrefix(s.RepoURL, "oci://") {
			return s.RepoURL
		}
	}
	return ""
}

func gitopsRepo(app string) string { return "https://example.test/gitops-" + app }

const chartRepo = "https://example.test/charts.git"

func live(w *world, name, wantOwner string, uid types.UID) func() (bool, string) {
	return func() (bool, string) {
		a := w.app(name)
		switch {
		case a == nil:
			return false, name + " is gone"
		case a.DeletionTimestamp != nil:
			return false, name + " is being deleted"
		case uid != "" && a.UID != uid:
			return false, name + " was deleted and created again (uid changed)"
		case owner(a) != wantOwner:
			return false, fmt.Sprintf("%s is owned by %q, want %q", name, owner(a), wantOwner)
		}
		return true, ""
	}
}

func TestGatedSet(t *testing.T) {
	w := start(t)
	// shop-dev: no clearanceGate; shop-prod: clearanceGate: true (what Airframe writes); pay-dev: clearanceGate: false
	// (Airframe never writes it, but the selector must still send it to tenant-onboarding).
	w.repo.set("tenants/shop/dev/identity.yaml", identity("shop", "dev", ""))
	w.repo.set("tenants/shop/prod/identity.yaml", identity("shop", "prod", "clearanceGate: true\n"))
	w.repo.set("tenants/pay/dev/identity.yaml", identity("pay", "dev", "clearanceGate: false\n"))
	// pay-prod: gated, with the configMapGenerator source (the templatePatch's three-source variant).
	w.repo.set("tenants/pay/prod/identity.yaml", identity("pay", "prod", "clearanceGate: true\nconfigMapGenerator: true\n"))
	w.apply(w.sets[tenantSet])
	w.apply(w.sets[gatedSet])

	t.Run("each environment is generated by exactly one set", func(t *testing.T) {
		w.t = t
		for name, want := range map[string]string{"shop-dev": tenantSet, "pay-dev": tenantSet, "shop-prod": gatedSet, "pay-prod": gatedSet} {
			w.eventually(name+" owned by "+want, live(w, name, want, ""))
		}
		w.steady("no set reports another's Application", 3*time.Second, func() (bool, string) {
			for _, s := range []string{tenantSet, gatedSet} {
				if m := w.setCondition(s); m != "" {
					return false, s + ": " + m
				}
			}
			return true, ""
		})
		var all argov1alpha1.ApplicationList
		if err := w.c.List(w.ctx, &all, client.InNamespace(ns)); err != nil {
			t.Fatal(err)
		}
		if len(all.Items) != 4 {
			t.Fatalf("want 4 Applications, got %d", len(all.Items))
		}
	})

	t.Run("only the gated set's Applications are opted in, and only they have no resources finalizer", func(t *testing.T) {
		w.t = t
		g, d := w.app("shop-prod"), w.app("shop-dev")
		if g.Annotations[protect] != "true" || has(g.Finalizers, finalizer) {
			t.Fatalf("shop-prod: annotations %v finalizers %v", g.Annotations, g.Finalizers)
		}
		if _, ok := d.Annotations[protect]; ok || !has(d.Finalizers, finalizer) {
			t.Fatalf("shop-dev: annotations %v finalizers %v", d.Annotations, d.Finalizers)
		}
		if g.Spec.Sources[0].Plugin != nil {
			t.Fatal("shop-prod was created on a plugin source: the agent would refuse to switch it")
		}
	})

	t.Run("a gated Application's carrier (first git source) is its gitops repository; tenant-onboarding's order is unchanged", func(t *testing.T) {
		w.t = t
		for _, c := range []struct{ name, app string }{{"shop-prod", "shop"}, {"pay-prod", "pay"}} {
			a := w.app(c.name)
			if got := carrier(a.Spec.Sources); got != gitopsRepo(c.app) {
				t.Fatalf("%s: the agent's carrier would be %q, want the gitops repository %q (sources %+v)", c.name, got, gitopsRepo(c.app), a.Spec.Sources)
			}
			if a.Spec.Sources[0].Ref != "appsrc" || a.Spec.Sources[1].RepoURL != chartRepo {
				t.Fatalf("%s: want [appsrc ref, chart, ...], got %+v", c.name, a.Spec.Sources)
			}
		}
		if p := w.app("pay-prod"); len(p.Spec.Sources) != 3 || !strings.HasSuffix(p.Spec.Sources[2].Path, "/prod/configmap") {
			t.Fatalf("pay-prod: want the configMapGenerator source third, got %+v", p.Spec.Sources)
		}
		d := w.app("shop-dev")
		if len(d.Spec.Sources) != 2 || d.Spec.Sources[0].RepoURL != chartRepo || d.Spec.Sources[1].Ref != "appsrc" {
			t.Fatalf("shop-dev (tenant-onboarding): want [chart, appsrc ref] as before, got %+v", d.Spec.Sources)
		}
	})

	// What the agent does when it switches an Application: one patch of the sources and its marker annotation.
	agentSwitch := func(name string) {
		a := w.app(name)
		patch := map[string]any{
			"metadata": map[string]any{"annotations": map[string]string{switched: "sources"}},
			"spec":     map[string]any{"sources": []any{map[string]any{"repoURL": carrier(a.Spec.Sources), "targetRevision": "main", "plugin": map[string]any{"name": "clearance"}}}},
		}
		b, _ := json.Marshal(patch)
		if err := w.c.Patch(w.ctx, a, client.RawPatch(types.MergePatchType, b)); err != nil {
			t.Fatal(err)
		}
	}
	onPlugin := func(name string) func() (bool, string) {
		return func() (bool, string) {
			a := w.app(name)
			if a == nil || len(a.Spec.Sources) != 1 || a.Spec.Sources[0].Plugin == nil {
				return false, fmt.Sprintf("%s is not on the plugin source", name)
			}
			if a.Annotations[switched] != "sources" {
				return false, fmt.Sprintf("%s lost the switched marker: %v", name, a.Annotations)
			}
			return true, ""
		}
	}

	t.Run("the gated set keeps the agent's switch (ignore rule and preservedFields)", func(t *testing.T) {
		w.t = t
		agentSwitch("shop-prod")
		w.refresh()
		w.steady("shop-prod stays switched across reconciles", 5*time.Second, onPlugin("shop-prod"))
	})

	t.Run("tenant-onboarding has neither: a switch there is reverted", func(t *testing.T) {
		w.t = t
		agentSwitch("pay-dev")
		w.refresh()
		w.eventually("pay-dev back on its Helm sources, marker gone", func() (bool, string) {
			a := w.app("pay-dev")
			if len(a.Spec.Sources) == 2 && a.Spec.Sources[0].Plugin == nil && a.Annotations[switched] == "" {
				return true, ""
			}
			return false, fmt.Sprintf("sources %d, annotations %v", len(a.Spec.Sources), a.Annotations)
		})
	})

	// The handover, tenant-onboarding to tenant-onboarding-gated, for shop-dev: the window, the flip, the ownership move.
	t.Run("handover into the gated set keeps the Application", func(t *testing.T) {
		w.t = t
		uid := w.app("shop-dev").UID
		w.apply(w.hsets[tenantSet])
		w.apply(w.hsets[gatedSet])
		w.observed(tenantSet)
		w.observed(gatedSet)
		w.repo.set("tenants/shop/dev/identity.yaml", identity("shop", "dev", "clearanceGate: true\n"))
		w.refresh()
		// tenant-onboarding stops generating it but, in the window, does not delete it; the gated set cannot take it yet.
		w.eventually("the gated set reports it cannot take shop-dev", func() (bool, string) {
			m := w.setCondition(gatedSet)
			return strings.Contains(m, "shop-dev") && strings.Contains(m, "already owned"), "condition: " + m
		})
		w.steady("shop-dev kept, still owned by tenant-onboarding", 5*time.Second, live(w, "shop-dev", tenantSet, uid))
		// The operator step: drop tenant-onboarding's controller reference, guarded by a test of its uid.
		a := w.app("shop-dev")
		var tenantUID types.UID
		for _, o := range a.OwnerReferences {
			if o.Name == tenantSet {
				tenantUID = o.UID
			}
		}
		// The same patch puts the $appsrc source first (the gated set's order): the set's ignore rule keeps the live sources on
		// adoption, so without the move the agent's carrier would stay the chart repository.
		jp := fmt.Sprintf(`[{"op":"test","path":"/metadata/ownerReferences/0/uid","value":%q},{"op":"test","path":"/spec/sources/1/ref","value":"appsrc"},`+
			`{"op":"move","from":"/spec/sources/1","path":"/spec/sources/0"},{"op":"remove","path":"/metadata/ownerReferences/0"}]`, tenantUID)
		if err := w.c.Patch(w.ctx, a, client.RawPatch(types.JSONPatchType, []byte(jp))); err != nil {
			t.Fatal(err)
		}
		w.refresh()
		w.eventually("the gated set adopts shop-dev", live(w, "shop-dev", gatedSet, uid))
		w.steady("shop-dev keeps the moved order under the gated set (carrier: its gitops repository)", 3*time.Second, func() (bool, string) {
			a := w.app("shop-dev")
			return carrier(a.Spec.Sources) == gitopsRepo("shop") && len(a.Spec.Sources) == 2, fmt.Sprintf("sources %+v", a.Spec.Sources)
		})
		w.eventually("shop-dev is opted in and lost the resources finalizer", func() (bool, string) {
			a := w.app("shop-dev")
			return a.Annotations[protect] == "true" && !has(a.Finalizers, finalizer), fmt.Sprintf("annotations %v finalizers %v", a.Annotations, a.Finalizers)
		})
		// Close the window: back to the ordinary sets. Nothing is deleted, nothing changes owner.
		w.apply(w.sets[tenantSet])
		w.apply(w.sets[gatedSet])
		w.steady("after the window: shop-dev kept by the gated set", 5*time.Second, live(w, "shop-dev", gatedSet, uid))
		w.steady("after the window: shop-prod untouched", time.Second, live(w, "shop-prod", gatedSet, ""))
		if m := w.setCondition(gatedSet) + w.setCondition(tenantSet); m != "" {
			t.Fatalf("an error is left on a set: %s", m)
		}
	})

	t.Run("handover back to tenant-onboarding keeps the Application", func(t *testing.T) {
		w.t = t
		agentSwitch("shop-dev")
		uid := w.app("shop-dev").UID
		w.apply(w.hsets[tenantSet])
		w.apply(w.hsets[gatedSet])
		w.observed(tenantSet)
		w.observed(gatedSet)
		w.repo.set("tenants/shop/dev/identity.yaml", identity("shop", "dev", ""))
		w.refresh()
		w.eventually("tenant-onboarding reports it cannot take shop-dev", func() (bool, string) {
			m := w.setCondition(tenantSet)
			return strings.Contains(m, "shop-dev") && strings.Contains(m, "already owned"), "condition: " + m
		})
		w.steady("shop-dev kept by the gated set, nothing rewrites it", 3*time.Second, func() (bool, string) {
			if ok, why := live(w, "shop-dev", gatedSet, uid)(); !ok {
				return false, why
			}
			return onPlugin("shop-dev")()
		})
		// Nothing reconciles shop-dev now, so the operator's opt-out sticks: here the annotation is removed and, standing in for
		// the agent's own restore, the original sources are put back (on a cluster: wait for the agent to do both).
		a := w.app("shop-dev")
		if err := w.c.Patch(w.ctx, a, client.RawPatch(types.JSONPatchType, []byte(`[{"op":"remove","path":"/metadata/annotations/clearance.hangar.io~1protect"}]`))); err != nil {
			t.Fatal(err)
		}
		w.steady("the opt-out annotation removal is not reverted", 2*time.Second, func() (bool, string) {
			_, ok := w.app("shop-dev").Annotations[protect]
			return !ok, "the protect annotation came back"
		})
		a = w.app("shop-dev")
		var gatedUID types.UID
		for _, o := range a.OwnerReferences {
			if o.Name == gatedSet {
				gatedUID = o.UID
			}
		}
		jp := fmt.Sprintf(`[{"op":"test","path":"/metadata/ownerReferences/0/uid","value":%q},{"op":"remove","path":"/metadata/ownerReferences/0"}]`, gatedUID)
		if err := w.c.Patch(w.ctx, a, client.RawPatch(types.JSONPatchType, []byte(jp))); err != nil {
			t.Fatal(err)
		}
		w.refresh()
		w.eventually("tenant-onboarding adopts shop-dev", live(w, "shop-dev", tenantSet, uid))
		w.eventually("shop-dev is back on its Helm sources with the resources finalizer", func() (bool, string) {
			a := w.app("shop-dev")
			return len(a.Spec.Sources) == 2 && a.Spec.Sources[0].Plugin == nil && a.Spec.Sources[0].RepoURL == chartRepo && has(a.Finalizers, finalizer) && a.Annotations[switched] == "",
				fmt.Sprintf("sources %d finalizers %v annotations %v", len(a.Spec.Sources), a.Finalizers, a.Annotations)
		})
		w.apply(w.sets[tenantSet])
		w.apply(w.sets[gatedSet])
		w.steady("after the window: shop-dev kept by tenant-onboarding", 5*time.Second, live(w, "shop-dev", tenantSet, uid))
	})

	// Why the window exists: a bare flip of clearanceGate makes tenant-onboarding delete the Application, and its resources
	// finalizer would then delete the workload. Recorded so a change in Argo CD's behaviour shows up here.
	t.Run("a bare flip outside the window deletes the Application (the failure the handover avoids)", func(t *testing.T) {
		w.t = t
		w.repo.set("tenants/pay/dev/identity.yaml", identity("pay", "dev", "clearanceGate: true\n"))
		w.refresh()
		w.eventually("tenant-onboarding deletes pay-dev, finalizer still on (cascade)", func() (bool, string) {
			a := w.app("pay-dev")
			if a != nil && a.DeletionTimestamp != nil && has(a.Finalizers, finalizer) {
				return true, ""
			}
			return false, fmt.Sprintf("pay-dev: %+v", a)
		})
	})
}
