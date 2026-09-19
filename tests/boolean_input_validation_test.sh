#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"token":"runner-token"}\n'
EOF

cat > "$tmp_dir/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GCLOUD_LOG}"
if [[ "$*" == *"compute instances describe"* ]]; then
  printf '{"labels":{"gh_ready":"1"}}\n'
fi
EOF

cat > "$tmp_dir/bin/marker-command" <<'EOF'
#!/usr/bin/env bash
touch "${MARKER_FILE}"
EOF
chmod +x "$tmp_dir/bin/curl" "$tmp_dir/bin/gcloud" "$tmp_dir/bin/marker-command"

run_action() {
  local preemptible=$1
  local ephemeral=$2
  local no_external_address=$3
  local actions_preinstalled=$4
  local arm=$5
  local maintenance_policy_terminate=$6
  rm -f "$tmp_dir/marker"
  : > "$tmp_dir/gcloud.log"
  set +e
  output=$(
    PATH="$tmp_dir/bin:$PATH" \
    GCLOUD_LOG="$tmp_dir/gcloud.log" \
    MARKER_FILE="$tmp_dir/marker" \
    GITHUB_REPOSITORY=example/repo \
    GITHUB_REPOSITORY_OWNER=example \
    GITHUB_RUN_ID=123 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_OUTPUT="$tmp_dir/output" \
    "$repo_root/action.sh" \
      --command=start \
      --token=test-token \
      --project_id= \
      --service_account_key= \
      --runner_ver=2.321.0 \
      --vm_name_prefix=test-runner \
      --machine_zone=us-east1-c \
      --machine_type=n1-standard-1 \
      --scopes=cloud-platform \
      --shutdown_timeout=30 \
      --preemptible="$preemptible" \
      --ephemeral="$ephemeral" \
      --no_external_address="$no_external_address" \
      --actions_preinstalled="$actions_preinstalled" \
      --arm="$arm" \
      --maintenance_policy_terminate="$maintenance_policy_terminate" \
      2>&1
  )
  status=$?
  set -e
}

assert_rejected() {
  local input_name=$1
  if [[ $status -eq 0 ]]; then
    printf 'expected %s to be rejected, got success\n%s\n' "$input_name" "$output" >&2
    if [[ -e "$tmp_dir/marker" ]]; then
      printf 'marker executable ran\n' >&2
    fi
    exit 1
  fi
  if [[ "$output" != *"Invalid ${input_name}"* ]]; then
    printf 'missing invalid-input error for %s:\n%s\n' "$input_name" "$output" >&2
    exit 1
  fi
  if [[ -e "$tmp_dir/marker" ]]; then
    printf 'marker executable ran for rejected %s\n' "$input_name" >&2
    exit 1
  fi
  if [[ -s "$tmp_dir/gcloud.log" ]]; then
    printf 'gcloud ran for rejected %s\n' "$input_name" >&2
    exit 1
  fi
}

run_action false false false marker-command false ''
assert_rejected actions_preinstalled

run_action sometimes false false false false ''
assert_rejected preemptible

run_action false '' false false false ''
assert_rejected ephemeral

run_action false false TRUE false false ''
assert_rejected no_external_address

run_action false false false false 'false ' ''
assert_rejected arm

run_action false false false false false enabled
assert_rejected maintenance_policy_terminate

run_action false false false false false ''
if [[ $status -ne 0 ]]; then
  printf 'valid false/empty inputs failed:\n%s\n' "$output" >&2
  exit 1
fi
if grep -q -- '--provisioning-model=SPOT\|--ephemeral\|--no-address\|--maintenance-policy=TERMINATE' "$tmp_dir/gcloud.log"; then
  printf 'false Boolean inputs unexpectedly enabled flags\n' >&2
  exit 1
fi

run_action true true true true true true
if [[ $status -ne 0 ]]; then
  printf 'valid true inputs failed:\n%s\n' "$output" >&2
  exit 1
fi
for expected_flag in '--provisioning-model=SPOT' '--no-address' '--maintenance-policy=TERMINATE'; do
  if ! grep -q -- "$expected_flag" "$tmp_dir/gcloud.log"; then
    printf 'missing flag for true input: %s\n' "$expected_flag" >&2
    exit 1
  fi
done

for input_name in preemptible ephemeral no_external_address actions_preinstalled arm maintenance_policy_terminate; do
  if grep -Fq -- "--${input_name}=\${{ inputs.${input_name} }}" "$repo_root/action.yml"; then
    printf '%s is still rendered directly into shell source\n' "$input_name" >&2
    exit 1
  fi
done

printf 'Boolean input validation tests passed\n'
