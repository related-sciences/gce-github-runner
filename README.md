# gce-github-runner
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
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
        uses: related-sciences/gce-github-runner@v0.4
        with:
          token: ${{ secrets.GH_SA_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2004-lts

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
      - uses: related-sciences/gce-github-runner@v0.4
        with:
          command: stop
        if: always()
```

 * `create-runner` creates the GCE VM and registers the runner with unique label
 * `test` uses the runner, and destroys it as the last step

## Inputs

See inputs and descriptions [here](./action.yml).

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * `at`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
