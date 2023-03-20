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

command=
token=
project_id=
service_account_key=
runner_ver=
machine_zone=
machine_type=
disk_size=
gpu=
runner_service_account=
image_project=
image=
image_family=
network=
scopes=
shutdown_timeout=
subnet=
preemptible=
ephemeral=
no_external_address=
actions_preinstalled=
arm=

OPTLIND=1
while getopts_long :h opt \
  command required_argument \
  token required_argument \
  project_id required_argument \
  service_account_key required_argument \
  runner_ver required_argument \
  machine_zone required_argument \
  machine_type required_argument \
  disk_size optional_argument \
  gpu optional_argument \
  runner_service_account optional_argument \
  image_project optional_argument \
  image optional_argument \
  image_family optional_argument \
  network optional_argument \
  scopes required_argument \
  shutdown_timeout required_argument \
  subnet optional_argument \
  preemptible required_argument \
  ephemeral required_argument \
  no_external_address required_argument \
  actions_preinstalled required_argument \
  arm required_argument \
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
      disk_size=${OPTLARG-$disk_size}
      ;;
    gpu)
      gpu=${OPTLARG-$gpu}
      ;;
    runner_service_account)
      runner_service_account=${OPTLARG-$runner_service_account}
      ;;
    image_project)
      image_project=${OPTLARG-$image_project}
      ;;
    image)
      image=${OPTLARG-$image}
      ;;
    image_family)
      image_family=${OPTLARG-$image_family}
      ;;
    network)
      network=${OPTLARG-$network}
      ;;
    scopes)
      scopes=$OPTLARG
      ;;
    shutdown_timeout)
      shutdown_timeout=$OPTLARG
      ;;
    subnet)
      subnet=${OPTLARG-$subnet}
      ;;
    preemptible)
      preemptible=$OPTLARG
      ;;
    ephemeral)
      ephemeral=$OPTLARG
      ;;
    no_external_address)
      no_external_address=$OPTLARG
      ;;
    actions_preinstalled)
      actions_preinstalled=$OPTLARG
      ;;
    arm)
      arm=$OPTLARG
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
  # NOTE: when --project is specified, it updates the config
  echo ${service_account_key} | gcloud --project  ${project_id} --quiet auth activate-service-account --key-file - &>/dev/null
  echo "✅ Successfully configured gcloud."
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
  echo "✅ Successfully got the GitHub Runner registration token"

  VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  preemptible_flag=$([[ "${preemptible}" == "true" ]] && echo "--preemptible" || echo "")
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  no_external_address_flag=$([[ "${no_external_address}" == "true" ]] && echo "--no-address" || echo "")
  network_flag=$([[ ! -z "${network}"  ]] && echo "--network=${network}" || echo "")
  subnet_flag=$([[ ! -z "${subnet}"  ]] && echo "--subnet=${subnet}" || echo "")
  gpu_flag=$([[ ! -z "${gpu}"  ]] && echo "--accelerator=\"${gpu}\"" || echo "")

  echo "The new GCE VM will be ${VM_ID}"

  startup_script="
    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \\
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended ${ephemeral_flag} --disableupdate && \\
    ./svc.sh install && \\
    ./svc.sh start && \\
    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
    # Install at if not installed
    command -v at >/dev/null 2>&1 ||  apt-get install -y -q at
    # 1 days represents the max workflow runtime. This will shutdown the instance if everything else fails.
    echo \"gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}\" | at now + 1 days
    "

  if $actions_preinstalled ; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    startup_script="#!/bin/bash
    cd /actions-runner
    $startup_script"
  else
    echo "✅ Startup script will install GitHub Actions"
    if $arm ; then
      startup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-arm64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-arm64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-arm64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh && \\
      $startup_script"
    else
      startup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh && \\
      $startup_script"
    fi
  fi

  echo " 
  CMD = gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    ${disk_size_flag} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    ${image_project_flag} \
    ${image_flag} \
    ${image_family_flag} \
    ${preemptible_flag} \
    ${no_external_address_flag} \
    ${subnet_flag} \
    ${gpu_flag} \
    --labels=gh_ready=0 \
    --metadata=startup-script=\"$startup_script\" \
    && echo "label=${VM_ID}" >> $GITHUB_OUTPUT
  "

  gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    ${disk_size_flag} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    ${image_project_flag} \
    ${image_flag} \
    ${image_family_flag} \
    ${preemptible_flag} \
    ${no_external_address_flag} \
    ${subnet_flag} \
    ${gpu_flag} \
    --labels=gh_ready=0 \
    --metadata=startup-script="$startup_script" \
    && echo "label=${VM_ID}" >> $GITHUB_OUTPUT

  safety_off
  while (( i++ < 60 )); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      break
    fi
    echo "${VM_ID} not ready yet, waiting 5 secs ..."
    sleep 5
  done
  if [[ $GH_READY == 1 ]]; then
    echo "✅ ${VM_ID} ready ..."
  else
    echo "Waited 5 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
    # gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}
    exit 1
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
  echo "✅ Self deleting $NAME in $ZONE in ${shutdown_timeout} seconds ..."
  echo "sleep ${shutdown_timeout}; gcloud --quiet compute instances delete $NAME --zone=$ZONE" | env at now
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
