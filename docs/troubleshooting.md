# Troubleshooting

## Infrastructure

### Terraform apply fails with "Error creating VPC"

Your AWS credentials may lack permissions.  The IAM user/role needs:
- `ec2:*` (VPC, subnets, SGs, instances)
- `iam:CreateRole`, `iam:CreateInstanceProfile`, `iam:PassRole`
- `iam:AttachRolePolicy`

### Services not healthy after `make up`

User-data scripts run asynchronously after instance launch.  Wait 3-5 minutes
after Terraform completes, then check:

```bash
# SSH to the instance and check logs
ssh -i $SSH_PRIVATE_KEY_PATH ec2-user@<public-ip>
sudo tail -f /var/log/userdata-payment-svc.log
```

Common issues:
- **Package install failure:** Amazon Linux repos may be slow.  Wait and retry.
- **Kafka not starting:** Check `/var/log/userdata-kafka.log` for Java version
  issues.
- **PostgreSQL init failure:** Check `/var/log/userdata-postgres.log`.

### Cannot SSH to private-subnet instances (Kafka, PostgreSQL)

These instances are on private subnets with no public IPs.  Access them via:
1. SSH agent forwarding through a service instance (which has a public IP)
2. AWS Systems Manager Session Manager (SSM is enabled on all instances)

## ServiceNow

### `make seed-cmdb` fails with 401

Verify your ServiceNow credentials in `.env`.  PDI instances sleep after
inactivity — log in via browser first to wake the instance.

### Relationship type not found

The `setup_cmdb.py` script looks up relationship types by `parent_descriptor`.
If your ServiceNow instance uses different names (e.g. localised labels),
edit `cmdb/ci_definitions.yml` to match your instance's relationship type
names.  Check available types:

```
https://your-instance.service-now.com/api/now/table/cmdb_rel_type?sysparm_fields=parent_descriptor,child_descriptor,sys_id
```

### Duplicate CIs after re-running setup

The script checks for CIs with `[aiops-demo]` in the description.  If you
manually edited CI descriptions and removed this tag, the script will create
duplicates.  Run `make teardown-cmdb` first, then `make seed-cmdb`.

## Demo flow

### Break playbook reports "no change"

The config file may already be in the broken state.  Run `make reset` first
to restore it, then `make demo-break`.

### Diagnostic orchestrator can't find the business service

The incident must have its `business_service` field set to the sys_id of the
"Passport online application service" CI.  The `make demo-incident` target
sets the business service by name — if ServiceNow can't resolve it, set it
manually in the incident form.

### ALIA module fails

If `ALIA_MODE=live` and the endpoint is unreachable, the module will fail.
Switch to `ALIA_MODE=mock` in `.env` for reliable demo results.

### Traffic generator connection refused

The payment-svc may not be ready yet.  The generator retries on connection
errors.  Check that the payment-svc public IP is correct and port 5000 is
accessible (security group allows it).

## Ansible

### Dynamic inventory returns no hosts

Ensure:
1. AWS credentials are configured (env vars or profile)
2. `boto3` is installed: `pip install boto3`
3. Instances are running and tagged with `Project=aiops-demo`
4. The `AWS_REGION` in `.env` matches where you deployed

Test with:
```bash
ansible-inventory -i inventory/aws_ec2.yml --graph
```

### Playbook fails to connect to hosts

Check:
- `SSH_PRIVATE_KEY_PATH` points to the correct key file
- The key file permissions are `0600`
- The username is `ec2-user` (Amazon Linux default)
- Security groups allow SSH from your network
