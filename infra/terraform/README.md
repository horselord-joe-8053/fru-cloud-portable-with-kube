# Terraform (EKS + VPC) — Tagged by PROJECT_ID

Terraform is idempotent: running `apply` multiple times converges to the same infra.

## Identity & tagging
All AWS resources created here are tagged with:
- `ProjectId = <PROJECT_ID>`
- `Project = <CLUSTER_NAME>`
- `ManagedBy = terraform`

The EKS cluster name is also suffixed with `-<PROJECT_ID>` to avoid collisions:
`<CLUSTER_NAME>-<PROJECT_ID>`
