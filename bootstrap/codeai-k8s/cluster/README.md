# cluster

Creates the EKS Fargate cluster along with required VPC subnets, NAT gateways, IAM,
and core cluster outputs for later ordered roots.

Apply this first, before `../cluster-infra/`.

## Usage

If this is the **first time you've setup this cluster**, follow [first time cluster setup](#first-time-cluster-setup)

```bash
tofu init

# Apply requires admin (IAM roles are created)
AWS_PROFILE=codeorg-admin tofu apply
```

Configure `kubectl` to reach the new cluster:

```bash
$(tofu output -raw kubectl_config_command)
```

## First time cluster setup

1. Tofu module `../../codeai-k8s-dex` needs to have been applied at least once (its shared by all clusters)
1. Run tofu apply: `AWS_PROFILE=codeorg-admin tofu apply`

## Smoke Tests

### Can you start a Pod and can it reach DNS?

Takes a few minutes cause fargate is slooooow.

```bash
./test/test-pod-and-dns.sh
```
