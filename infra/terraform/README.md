# AIOps demo – Terraform (EC2 on AWS)

This directory contains Terraform that provisions a **self-managed** AIOps-style demo stack: **one VPC**, **one public subnet** and **two private subnets (two AZs)**, a **NAT gateway** for private outbound access, and **four EC2 instances** running open-source software only (no RDS, SQS, MSK, or other managed data-plane services in this project).

| Instance    | Type (default) | Subnet  | Software |
|------------|------------------|---------|----------|
| `kafka`    | `t3.medium`     | private | Apache Kafka 3.7 (KRaft), Corretto 17, Flask admin shim on 8080, JMX 9999 |
| `postgres` | `t3.small`      | private | PostgreSQL 16 |
| `payment-svc` | `t3.small`   | public  | Python 3.11, Flask, Kafka producer, port 5000 |
| `app-svc`  | `t3.small`      | public  | Python 3.11, Flask, Kafka consumer, PostgreSQL, port 5001 |

All resources are tagged with **`Project=<project_tag>`** (default `aiops-demo`) and **`Environment=demo`**.

## Security (important)

- **SSH from the Internet (0.0.0.0/0) on port 22** is enabled only via **`bastion-sg`**, which is attached to the **public** service instances (payment and app) so you can open an SSH session for the demo. This is **not appropriate for production**; restrict the source in `network.tf` (e.g. to your home/office CIDR) if you use this past a throwaway account.
- **Kafka, PostgreSQL, and JMX** are reachable only from the **VPC CIDR** (and SSH to those hosts is allowed only from the VPC, not from the public Internet). Use a jump via the public instances or SSM to reach them if needed.
- `services-sg` allows **HTTP/HTTPS-style demo ports 5000 and 5001 from anywhere** for easy demos.

## What Terraform creates (summary)

- VPC `10.0.0.0/16` (configurable) with IGW, one NAT gateway, and route tables: public to IGW, private subnets to NAT.
- One public subnet (`10.0.1.0/24`) and two private subnets (`10.0.2.0/24`, `10.0.3.0/24`) in two AZs.
- Security groups: `bastion-sg`, `kafka-sg`, `postgres-sg`, `services-sg` with tiered rules as described in `network.tf`.
- IAM **instance profile** with **only** `AmazonSSMManagedInstanceCore` (SSM agent / Session Manager convenience).
- Four EC2 instances (Amazon Linux 2023) with user data under `userdata/`.

## Prerequisites

- **Terraform** `>= 1.5.0` ([Install Terraform](https://developer.hashicorp.com/terraform/install)).
- **AWS credentials** configured (e.g. environment variables, shared credentials file, or an IAM role) with permission to create VPC, EC2, IAM, and related objects in the target account/region.
- An **EC2 key pair** already created in the **same region** you deploy to; pass its name as `ssh_key_name`.

## Usage

1. `cd` into this directory (`infra/terraform`).

2. Create a `terraform.tfvars` (or pass variables on the command line), for example:

   ```hcl
   aws_region   = "eu-west-2"
   ssh_key_name = "my-keypair"
   # Optional overrides: project_tag, vpc_cidr, instance types, etc.
   ```

3. Initialize and apply:

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. After apply, use **`terraform output`** to get **public and private IP addresses** for all four instances, plus dedicated outputs for the Kafka and PostgreSQL private IPs. The public payment/app URLs (for a quick test) are:

   - `http://<payment_svc public>:5000/health` and `POST /pay` with JSON.
   - `http://<app_svc public>:5001/health`
   - Kafka admin (from a host inside the VPC, or via port forward): `http://<kafka private>:8080/health` (not exposed on 0.0.0.0/0 in the default security groups).

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `eu-west-2` | AWS region. |
| `project_tag` | `aiops-demo` | `Project` tag on all resources. |
| `vpc_cidr` | `10.0.0.0/16` | VPC IPv4 CIDR. **Note:** `userdata/postgres.sh` is aligned to `10.0.0.0/16` in `pg_hba.conf`; if you change `vpc_cidr`, update that script accordingly. |
| `kafka_instance_type` | `t3.medium` | Kafka node size. |
| `postgres_instance_type` | `t3.small` | Postgres node size. |
| `services_instance_type` | `t3.small` | Public service nodes. |
| `ssh_key_name` | (required) | EC2 key pair name. |

## Files

- `main.tf` – provider pin, Amazon Linux 2023 AMI data source, AZs, common tag locals.
- `network.tf` – networking and security groups.
- `compute.tf` – instance profile/role for SSM.
- `kafka.tf`, `postgres.tf`, `services.tf` – instances and user data (user data is templated for services with `templatefile` where needed).
- `outputs.tf` – IPs and grouped map.
- `userdata/` – bootstrap scripts (Kafka, PostgreSQL, payment-svc, app-svc).
