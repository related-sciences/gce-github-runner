#!/usr/bin/env bash

ACTION_DIR="$( cd $( dirname "${BASH_SOURCE[0]}" ) >/dev/null 2>&1 && pwd )"

function usage {
  echo "Usage: ${0} --command=[start|stop] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

source "${ACTION_DIR}/vendor/getopts_long.sh"

runner_service_account=
service_account_key=
project_id=

OPTLIND=1
while getopts_long :h opt \
  command required_argument \
  token required_argument \
  project_id required_argument \
  service_account_key required_argument \
  runner_ver required_argument \
  machine_zone required_argument \
  machine_type required_argument \
  disk_size required_argument \
  runner_service_account optional_argument \
  scopes required_argument \
  shutdown_timeout required_argument \
  help no_argument "" "$@"
do
  case "$opt" in
    command)
      command=$OPTLARG
      ;;
    token)
      token=$OPTLARG
      ;;
    project_id)
      project_id=$OPTLARG
      ;;
    service_account_key)
      service_account_key="$OPTLARG"
      ;;
    runner_ver)
      runner_ver=$OPTLARG
      ;;
    machine_zone)
      machine_zone=$OPTLARG
      ;;
    machine_type)
      machine_type=$OPTLARG
      ;;
    disk_size)
      disk_size=$OPTLARG
      ;;
    runner_service_account)
      runner_service_account=$OPTLARG
      ;;
    scopes)
      scopes=$OPTLARG
      ;;
    shutdown_timeout)
      shutdown_timeout=$OPTLARG
      ;;
    h|help)
      usage
      exit 0
      ;;
    :)
      printf >&2 '%s: %s\n' "${0##*/}" "$OPTLERR"
      usage
      exit 1
      ;;
  esac
done

function gcloud_auth {
  # NOTE: when --project is specified, it updated the config
  echo ${service_account_key} | gcloud --project  ${project_id} --quiet auth activate-service-account --key-file - >/dev/null
  echo "Successfully configured gcloud."
}

function start_vm {
  echo "Starting GCE VM ..."
  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  RUNNER_TOKEN=$(curl -S -s -XPOST \
      -H "authorization: Bearer ${token}" \
      https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token |\
      jq -r .token)
  echo "Successfully got the GitHub Runner registration token"

  VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${RANDOM}"
  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  echo "The new GCE VM will be ${VM_ID}"

  gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    --boot-disk-size=${disk_size} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    --labels=gh_ready=0 \
    --metadata=startup-script="#! /bin/bash
    mkdir actions-runner && cd actions-runner
    curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
    tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
    # TODO: this should be removed or configurable?
    apt-get update && apt-get install docker.io at -y
    # Next few cmds must all be successful at the same time otherwise GH will delete this VM
    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \\
    ./bin/installdependencies.sh && \\
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended && \\
    ./svc.sh install && \\
    ./svc.sh start && \\
    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
    # 3 days represents the max workflow runtime. This will shutdown the instance if everything else fails.
    echo \"gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}\" | at now + 3 days
    " && echo "::set-output name=label::${VM_ID}"

  safety_off
  while (( i++ < 24 )); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      break
    fi
    echo "${VM_ID} not ready yet, waiting 5 secs ..."
    sleep 5
  done
  if [[ $GH_READY == 0 ]]; then
    echo "Waited 2 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
    gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}
    exit 1
  else
    echo "${VM_ID} ready ..."
  fi
}

function stop_vm {
  # NOTE: this function runs on the GCE VM
  echo "Stopping GCE VM ..."
  # NOTE: it would be nice to gracefully shut down the runner, but we actually don't need
  #       to do that. VM shutdown will disconnect the runner, and GH will unregister it
  #       in 30 days
  # TODO: RUNNER_ALLOW_RUNASROOT=1 /actions-runner/config.sh remove --token $TOKEN
  NAME=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/name -H 'Metadata-Flavor: Google')
  ZONE=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/zone -H 'Metadata-Flavor: Google')
  echo "Self deleting $NAME in $ZONE in ${shutdown_timeout} seconds ..."
  echo "sleep ${shutdown_timeout}; gcloud --quiet compute instances delete $NAME --zone=$ZONE" | at now
}

safety_on
case "$command" in
  start)
    start_vm
    ;;
  stop)
    stop_vm
    ;;
  *)
    echo "Invalid command: \`${command}\`, valid values: start|stop" >&2
    usage
    exit 1
    ;;
esac
