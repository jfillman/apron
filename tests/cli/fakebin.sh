# Sourced by tests: fake kubectl/kiac/kind/gh/docker/container on PATH. Each logs "tool argv" to $FAKE_LOG.
# Behaviour is scripted by files in $FAKE_STATE: contexts (one per line), secrets ("ns/name" per line),
# clusters-kiac / clusters-kind (names), repos (owner/name).
make_fakes() {
  local bin="$1"; mkdir -p "${bin}"
  local t
  for t in kubectl kiac kind gh docker container; do
    cat >"${bin}/${t}" <<'SH'
#!/usr/bin/env bash
tool="$(basename "$0")"; echo "${tool} $*" >>"${FAKE_LOG}"
S="${FAKE_STATE}"; touch "$S/contexts" "$S/secrets" "$S/clusters-kiac" "$S/clusters-kind" "$S/repos"
args=" $* "
case "${tool}" in
  kubectl)
    case "${args}" in
      *" config get-contexts "*) cat "$S/contexts" ;;
      *" config rename-context "*) set -- $*; sed -i "s/^$3\$/$4/" "$S/contexts" ;;
      *" get secret "*) ns="$(sed -E 's/.* -n ([^ ]+) .*/\1/' <<<"${args}")"; n="$(sed -E 's/.* get secret ([^ ]+).*/\1/' <<<"${args}")"
                        grep -qx "${ns}/${n}" "$S/secrets" ;;
      *" get --raw /readyz "*) ctx="$(sed -E 's/.*--context ([^ ]+).*/\1/' <<<"${args}")"; grep -qx "${ctx}" "$S/contexts" ;;
      *" get namespace "*|*" get daemonset "*) exit 1 ;;
      *" get nodes "*) echo "node/$(head -n1 "$S/contexts")-control-plane" ;;
      *) exit 0 ;;
    esac ;;
  kiac) case "${args}" in *" get clusters "*) echo "NAME STATUS"; cat "$S/clusters-kiac" ;;
          *" create cluster "*) set -- $*; echo "$4" >>"$S/clusters-kiac"; echo "kiac-$4" >>"$S/contexts" ;; esac ;;
  kind) case "${args}" in *" get clusters "*) cat "$S/clusters-kind" ;;
          *" create cluster "*) set -- $*; echo "$4" >>"$S/clusters-kind"; echo "kind-$4" >>"$S/contexts" ;; esac ;;
  gh) case "${args}" in *" repo view "*) set -- $*; grep -qx "$3" "$S/repos" ;;
        *" repo create "*) set -- $*; echo "$3" >>"$S/repos" ;; esac ;;
esac
SH
    chmod +x "${bin}/${t}"
  done
}
