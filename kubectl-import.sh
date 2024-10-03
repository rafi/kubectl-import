#!/usr/bin/env bash
#
# kubectl-import - merge kubeconfigs stored as Kubernetes secrets or files.
#
# Requires yq, https://github.com/mikefarah/yq
# fzf, https://github.com/junegunn/fzf
# and kubectl.
#
# 2024-10-03 - file and stdin support
# 2024-09-30 - merge into existing kubeconfig
# 2023-08-09 - add namespace selection
# 2022-09-09 - initial version
set -eu

KUBECONFIG="${KUBECONFIG:=$HOME/.kube/config}"

function usage() {
	local prog; prog="$(basename "$0")"
	cat <<EOF
USAGE: $prog [--url str|--jsonpath str] [namespace] [secret name]
       $prog [-f|--file str]
       $prog < <file>
       $prog -d|--delete
       $prog -e|--edit
       $prog --help

KUBECONFIG="~${KUBECONFIG#"$HOME"}"

[options]
	--url str:       set server url when importing secret, e.g. https://localhost:6443
	--jsonpath str:  jsonpath for kubectl get secret, default: {.data.kubeconfig\.conf}
	-f, --file str:  import specified kubeconfig file
	-d, --delete:    delete context interactively
	-e, --edit:      edit kubeconfig
	-h, --help:      this help overview
EOF
}

function select_namespace() {
	# Use fzf to prompt user to select namespace.
	kubectl get namespaces \
		| fzf --exit-0 --ansi --info=right --height=50% --no-preview \
				--header-lines 1 --margin=1,3,0,3 --scrollbar=▏▕ \
				--prompt 'Select namespace to look for secrets> ' \
		| awk '{print $1}'
}

function select_secret() {
	# Use fzf to prompt user to select secret.
	kubectl get secrets -n "$__namespace" --field-selector type=Opaque \
		| fzf --exit-0 --ansi --info=right --height=50% --no-preview \
				--header-lines 1 --margin=1,3,0,3 --scrollbar=▏▕ \
				--prompt 'Select secret to merge in kubeconfig> ' \
		| awk '{print $1}'
}

function validate_secret() {
	if ! kubectl get secret -n "$__namespace" "$__secret_name" 1>/dev/null; then
		echo >&2 "Secret '${__secret_name}' doesn't exist in __namespace '${__namespace}', aborting."
		exit 3
	fi
}

function merge_secret() {
	# Concat final path name
	local context_name; context_name="$(kubectl config current-context)"
	local tmpfile; tmpfile="$(mktemp -p "$__cache_dir" -t secret)"
	# shellcheck disable=SC2064
	trap "rm -f '$tmpfile'" EXIT

	# Get secret contents, decode and save as file.
	kubectl get secret "$__secret_name" -n "$__namespace" \
		-o jsonpath='{.data.kubeconfig\.conf}' | base64 --decode > "${tmpfile}"

	# Update cluster server URL, if user has requested to.
	if [ -n "$__apiserver_url" ]; then
		yq -i ".clusters[].cluster.server = \"${__apiserver_url}\"" "${tmpfile}"
	fi

	# Change context name to be more verbose.
	local name="${context_name}-${__namespace}-${__secret_name}"
	yq -i ".contexts[].name = \"$name\"" "${tmpfile}"
	yq -i ".contexts[].context.cluster = \"$name\"" "${tmpfile}"
	yq -i ".contexts[].context.user = \"$name\"" "${tmpfile}"
	yq -i ".clusters[].name = \"$name\", .users[].name = \"$name\"" "${tmpfile}"
	merge_and_switch "$tmpfile" "$name"
}

function merge_stdin() {
	local stdin; stdin=$(cat)
	local tmpfile; tmpfile="$(mktemp -p "$__cache_dir" -t stdin)"
	# shellcheck disable=SC2064
	trap "rm -f '$tmpfile'" EXIT
	echo "$stdin" > "$tmpfile"
	merge_file "$tmpfile"
}

function merge_file() {
	local file="$1"
	local ctx; ctx="$(KUBECONFIG="$file" kubectl config current-context)"
	merge_and_switch "$file" "$ctx"
}

function merge_and_switch() {
	local src="$1"
	local ctx="$2"

	local merged; merged="$(mktemp -p "$__cache_dir" -t merged)"
	KUBECONFIG="$KUBECONFIG:$src" kubectl config view --flatten > "$merged"

	# Use new context, ensuring everything is in place, and overwrite kubeconfig.
	if KUBECONFIG="$merged" kubectl config use-context "$ctx"; then
		cp -fv "$HOME/.kube/config"{,.bak}
		mv -f "$merged" "$HOME/.kube/config"
	else
		echo >&2 'Failed to merge kubeconfig, aborting.'
		rm -f "$merged"
	fi
}

function main() {
	local __namespace='' __secret_name='' __apiserver_url=''
	local __jsonpath='{.data.kubeconfig\.conf}'
	local __cache_dir="$HOME/.kube/cache/import"
	local want_delete=0 want_file=''
	local positional=()

	while [ $# -gt 0 ]; do
		case "$1" in
		--url) shift; __apiserver_url="$1";;
		--jsonpath) shift; __jsonpath="$1";;
		-f|--file) want_file="$1";;
		-d|--delete) want_delete=1;;
		-e|--edit) "${EDITOR:-vi}" -O "${KUBECONFIG//:/ }"; exit;;
		-h|--help) usage; exit;;
		-*) echo "Warning, unrecognized option ${1}" >&2; exit 1;;
		*) positional+=("${1}");;
		esac
		shift
	done
	set -- "${positional[@]}"

	# Delete context if requested.
	if [ "$want_delete" = 1 ]; then
		__context_name="$(kubectl config get-contexts -o name | fzf)"
		test -n __context_name && kubectl config delete-context "$__context_name"
		return
	fi

	mkdir -p "$__cache_dir"

	# Merge kubeconfig from stdin if any.
	if [ -n "$want_file" ]; then
		merge_file "$1"
		return
	elif test ! -t 0; then
		merge_stdin
		return
	fi

	# Select namespace and secret, validate and merge.
	__namespace="${1:-}"
	__secret_name="${2:-}"

	if [ -z "$__namespace" ]; then
		__namespace="$(select_namespace)"
		if [ -z "$__namespace" ]; then
			echo >&2 'No namespace selected, aborting.'
			exit 2
		fi
	fi

	if [ -z "$__secret_name" ]; then
		__secret_name="$(select_secret)"
		if [ -z "$__secret_name" ]; then
			echo >&2 'No secret selected, aborting.'
			exit 2
		fi
	fi

	validate_secret
	merge_secret
}

main "$@"

# vim: set ts=2 sw=0 tw=80 noet :
