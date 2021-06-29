# gce-github-runner
[![Pre-commit](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml)
[![Test](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml)

Ephemeral GCE GitHub self-hosted runner.

## Usage

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - id: create-runner
        uses: related-sciences/gce-github-runner@v0.2
        with:
          token: ${{ secrets.GH_SA_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
      - uses: related-sciences/gce-github-runner@v0.2
        with:
          command: stop
        if: always()
```

 * `create-runner` creates the GCE VM and registers the runner with unique label
 * `test` uses the runner, and destroys it as the last step

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `command` | True | `start` | `start` or `stop` of the runner. |
| `token` | True |  | GitHub auth token, needs `repo`/`public_repo` scope: https://docs.github.com/en/rest/reference/actions#self-hosted-runners. |
| `project_id` | True |  | ID of the Google Cloud Platform project. If provided, this will configure gcloud to use this project ID. |
| `service_account_key` | True |  | The service account key which will be used for authentication credentials. This key should be created and stored as a secret. Should be JSON key. |
| `runner_ver` | True | `2.278.0` | Version of the GitHub Runner. |
| `machine_zone` | True | `us-east1-c` | GCE zone. |
| `machine_type` | True | `n1-standard-4` | GCE machine type: https://cloud.google.com/compute/docs/machine-types |
| `disk_size` | False |  | VM disk size. |
| `runner_service_account` | False |  | Service account of the VM, defaults to default compute service account. Should have the permission to delete VMs (self delete). |
| `image_project` | False |  | The Google Cloud project against which all image and image family references will be resolved. |
| `image` | False |  | Specifies the name of the image that the disk will be initialized with. |
| `image_family` | False |  | The image family for the operating system that the boot disk will be initialized with. |
| `scopes` | True | `cloud-platform` | Scopes granted to the VM. |
| `shutdown_timeout` | True | `30` | Grace period for the `stop` command, in seconds. |
| `actions_preinstalled` | True | `false` | Whether the GitHub actions have already been installed at `/actions-runner`. |

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * `at`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.
