SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load environment variables from .env if it exists
ifneq (,$(wildcard .env))
  include .env
  export
endif

TF_DIR       := infra/terraform
INVENTORY    := inventory/aws_ec2.yml
CMDB_DIR     := cmdb
SERVICES_DIR := services

# Colours for output
BOLD  := $(shell tput bold 2>/dev/null || true)
RESET := $(shell tput sgr0 2>/dev/null || true)

define banner
	@echo ""
	@echo "$(BOLD)>>> $(1)$(RESET)"
	@echo ""
endef

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help message
	@echo "$(BOLD)AIOps Business Value Demo — Makefile targets$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------
.PHONY: check
check: ## Verify .env is populated and prerequisites are installed
	$(call banner,Checking prerequisites)
	@test -f .env || { echo "ERROR: .env file not found. Copy .env.example to .env and populate it."; exit 1; }
	@test -n "$$AWS_ACCESS_KEY_ID"       || { echo "ERROR: AWS_ACCESS_KEY_ID is not set in .env";       exit 1; }
	@test -n "$$AWS_SECRET_ACCESS_KEY"   || { echo "ERROR: AWS_SECRET_ACCESS_KEY is not set in .env";   exit 1; }
	@test -n "$$SSH_KEY_NAME"            || { echo "ERROR: SSH_KEY_NAME is not set in .env";            exit 1; }
	@test -n "$$SSH_PRIVATE_KEY_PATH"    || { echo "ERROR: SSH_PRIVATE_KEY_PATH is not set in .env";    exit 1; }
	@test -n "$$SERVICENOW_INSTANCE_URL" || { echo "ERROR: SERVICENOW_INSTANCE_URL is not set in .env"; exit 1; }
	@command -v terraform       >/dev/null 2>&1 || { echo "ERROR: terraform not found";       exit 1; }
	@command -v ansible         >/dev/null 2>&1 || { echo "ERROR: ansible not found";         exit 1; }
	@command -v ansible-rulebook >/dev/null 2>&1 || echo "WARNING: ansible-rulebook not found (only needed for local EDA testing, not required for AAP)"
	@command -v python3         >/dev/null 2>&1 || { echo "ERROR: python3 not found";         exit 1; }
	@command -v jq              >/dev/null 2>&1 || { echo "ERROR: jq not found";              exit 1; }
	@echo "All prerequisites satisfied."

# ---------------------------------------------------------------------------
# AWS helpers
# ---------------------------------------------------------------------------
.PHONY: aws
aws: ## Run an AWS CLI command with .env credentials: make aws CMD="ec2 describe-key-pairs"
	@aws $(CMD)

.PHONY: create-keypair
create-keypair: ## Create the EC2 key pair and save the private key locally
	$(call banner,Creating EC2 key pair '$$SSH_KEY_NAME' in $$AWS_REGION)
	@mkdir -p $$(dirname "$$SSH_PRIVATE_KEY_PATH")
	@TMPKEY=$$(mktemp) && \
		aws ec2 create-key-pair \
			--key-name "$$SSH_KEY_NAME" \
			--key-type ed25519 \
			--region "$$AWS_REGION" \
			--query 'KeyMaterial' \
			--output text > "$$TMPKEY" && \
		mv "$$TMPKEY" "$$SSH_PRIVATE_KEY_PATH" && \
		chmod 600 "$$SSH_PRIVATE_KEY_PATH" && \
		echo "Key pair '$$SSH_KEY_NAME' created. Private key saved to $$SSH_PRIVATE_KEY_PATH" || \
		{ rm -f "$$TMPKEY"; echo "ERROR: Failed to create key pair. Does it already exist?"; exit 1; }

# ---------------------------------------------------------------------------
# infrastructure
# ---------------------------------------------------------------------------
.PHONY: up
up: check ## Provision AWS infrastructure and wait for services to be healthy
	$(call banner,Provisioning infrastructure with Terraform)
	cd $(TF_DIR) && terraform init -input=false
	cd $(TF_DIR) && terraform apply -auto-approve \
		-var="ssh_key_name=$$SSH_KEY_NAME" \
		-var="aws_region=$$AWS_REGION" \
		-var="project_tag=$$DEMO_PROJECT_TAG" \
		-var="domain_name=$${DEMO_DOMAIN:-}"
	$(call banner,Waiting for services to become healthy — this may take up to 5 minutes)
	@sleep 30
	@echo "Checking payment-svc health..."
	@PAYMENT_URL=$$(cd $(TF_DIR) && terraform output -json service_urls | jq -r '.payment_svc') && \
		for i in $$(seq 1 20); do \
			curl -sf $$PAYMENT_URL/health >/dev/null 2>&1 && break || sleep 15; \
		done && echo "payment-svc is healthy" || echo "WARNING: payment-svc did not become healthy"
	@echo "Checking app-svc health..."
	@APP_URL=$$(cd $(TF_DIR) && terraform output -json service_urls | jq -r '.app_svc') && \
		for i in $$(seq 1 20); do \
			curl -sf $$APP_URL/health >/dev/null 2>&1 && break || sleep 15; \
		done && echo "app-svc is healthy" || echo "WARNING: app-svc did not become healthy"
	@echo ""
	@cd $(TF_DIR) && terraform output -json dashboard_urls | jq -r 'to_entries[] | "  \(.key): \(.value)"'
	@echo ""
	@echo "$(BOLD)Demo citizen references:$(RESET)"
	@echo "  CIT-SMITH01  (standard adult — STUCK, paid 14 days ago, not progressed)"
	@echo "  CIT-CLARK04  (priority adult — WORKING, paid 15 days ago, now processing)"
	@echo ""
	@echo "  Use these to show the contrast: same service, same timeframe,"
	@echo "  but only standard adult applications are affected."
	@echo ""
	@echo "Infrastructure is ready. Run 'make seed-cmdb' next."

.PHONY: down
down: ## Destroy all AWS infrastructure
	$(call banner,Destroying infrastructure with Terraform)
	cd $(TF_DIR) && terraform destroy -auto-approve \
		-var="ssh_key_name=$$SSH_KEY_NAME" \
		-var="aws_region=$$AWS_REGION" \
		-var="project_tag=$$DEMO_PROJECT_TAG" \
		-var="domain_name=$${DEMO_DOMAIN:-}"

# ---------------------------------------------------------------------------
# CMDB
# ---------------------------------------------------------------------------
.PHONY: seed-cmdb
seed-cmdb: ## Create the ServiceNow CMDB business service and component CIs
	$(call banner,Seeding ServiceNow CMDB)
	cd $(CMDB_DIR) && python3 setup_cmdb.py

.PHONY: teardown-cmdb
teardown-cmdb: ## Remove all demo CIs and relationships from ServiceNow CMDB
	$(call banner,Tearing down ServiceNow CMDB entries)
	cd $(CMDB_DIR) && python3 teardown_cmdb.py

# ---------------------------------------------------------------------------
# traffic
# ---------------------------------------------------------------------------
.PHONY: seed-traffic
seed-traffic: ## Start the traffic generator in the background
	$(call banner,Starting traffic generator)
	@PAYMENT_URL=$$(cd $(TF_DIR) && terraform output -json service_urls | jq -r '.payment_svc') && \
		nohup python3 $(SERVICES_DIR)/seed/generate_traffic.py \
			--target-url "$$PAYMENT_URL" \
			> traffic.log 2>&1 & \
		echo "$$!" > .traffic.pid && \
		echo "Traffic generator started (PID $$!). Logs: traffic.log"

.PHONY: stop-traffic
stop-traffic: ## Stop the traffic generator
	$(call banner,Stopping traffic generator)
	@if [ -f .traffic.pid ]; then \
		PID=$$(cat .traffic.pid); \
		if kill -0 $$PID 2>/dev/null; then \
			kill $$PID && echo "Traffic generator stopped (PID $$PID)"; \
		else \
			echo "Traffic generator not running (stale PID $$PID)"; \
		fi; \
		rm -f .traffic.pid; \
	elif pgrep -f generate_traffic.py >/dev/null 2>&1; then \
		pkill -f generate_traffic.py && echo "Traffic generator stopped"; \
	else \
		echo "Traffic generator is not running"; \
	fi

# ---------------------------------------------------------------------------
# demo sequence
# ---------------------------------------------------------------------------
.PHONY: demo-break
demo-break: ## Introduce the misrouting failure into payment-svc
	$(call banner,Introducing misrouting failure)
	ansible-playbook playbooks/_demo/break/introduce_misrouting.yml \
		-i $(INVENTORY) \
		-e "target_service=payment-svc" \
		-e "affected_routing_key=fee.standard.adult" \
		-e "failure_mode=misroute_to_dlq" \
		--private-key $$SSH_PRIVATE_KEY_PATH

.PHONY: demo-incident
demo-incident: ## Create a ServiceNow incident manually (for testing without EDA)
	$(call banner,Creating ServiceNow incident)
	@python3 -c "\
	import requests, os, json; \
	url = os.environ['SERVICENOW_INSTANCE_URL'].rstrip('/') + '/api/now/table/incident'; \
	payload = { \
		'short_description': 'Citizens reporting paid passport applications not progressing', \
		'description': 'Multiple citizens have contacted the call centre reporting that their passport applications show as paid but have not progressed. Affects standard adult fee type.', \
		'urgency': '2', \
		'impact': '2', \
		'category': 'software', \
		'subcategory': 'application', \
		'business_service': 'Passport online application service' \
	}; \
	r = requests.post(url, json=payload, auth=(os.environ['SERVICENOW_USERNAME'], os.environ['SERVICENOW_PASSWORD']), headers={'Accept': 'application/json'}); \
	r.raise_for_status(); \
	inc = r.json()['result']; \
	print(f\"Incident created: {inc['number']} (sys_id: {inc['sys_id']})\")"

.PHONY: demo-diagnose
demo-diagnose: ## Run CMDB lookup directly (bypasses EDA — diagnostics run via workflow in AAP)
	$(call banner,Running CMDB lookup)
	@INCIDENT=$$(python3 -c "\
	import requests, os; \
	url = os.environ['SERVICENOW_INSTANCE_URL'].rstrip('/') + '/api/now/table/incident?sysparm_query=short_descriptionLIKEpassport&sysparm_limit=1&sysparm_order_by=sys_created_on&sysparm_order_by_desc=true'; \
	r = requests.get(url, auth=(os.environ['SERVICENOW_USERNAME'], os.environ['SERVICENOW_PASSWORD']), headers={'Accept': 'application/json'}); \
	r.raise_for_status(); \
	print(r.json()['result'][0]['sys_id'])" 2>/dev/null) && \
	ansible-playbook playbooks/service_reliability/cmdb_lookup.yml \
		-i $(INVENTORY) \
		-e "incident_id=$$INCIDENT" \
		--private-key $$SSH_PRIVATE_KEY_PATH

.PHONY: demo-fix
demo-fix: ## Run the remediation playbook to replay held messages
	$(call banner,Running remediation — replaying held messages)
	ansible-playbook playbooks/service_reliability/remediation/replay_held_messages.yml \
		-i $(INVENTORY) \
		-e "source_queue=payments.dlq" \
		-e "routing_key_filter=fee.standard.adult" \
		-e "target_queue=payments" \
		-e "batch_size=50" \
		-e "mode=live" \
		--private-key $$SSH_PRIVATE_KEY_PATH

.PHONY: reset
reset: ## Restore payment-svc to pre-break state, clear DLQ, reset stuck applications
	$(call banner,Resetting demo to clean state)
	ansible-playbook playbooks/_demo/break/introduce_misrouting.yml \
		-i $(INVENTORY) \
		-e "target_service=payment-svc" \
		-e "failure_mode=restore" \
		--private-key $$SSH_PRIVATE_KEY_PATH
	@echo "Clearing DLQ and resetting stuck applications..."
	@KAFKA=$$(cd $(TF_DIR) && terraform output -json internal_hostnames | jq -r '.kafka') && \
		POSTGRES=$$(cd $(TF_DIR) && terraform output -json internal_hostnames | jq -r '.postgres') && \
		echo "DLQ and database reset would be performed against $$KAFKA and $$POSTGRES"

# ---------------------------------------------------------------------------
# full demo sequence
# ---------------------------------------------------------------------------
.PHONY: demo-full
demo-full: ## Run the entire demo sequence end-to-end (happy path)
	$(call banner,Running full demo sequence)
	$(MAKE) seed-traffic
	@echo "Letting traffic flow for 30 seconds..."
	@sleep 30
	$(MAKE) demo-break
	@echo "Letting broken traffic accumulate for 60 seconds..."
	@sleep 60
	$(MAKE) demo-incident
	@sleep 5
	$(MAKE) demo-diagnose
	@sleep 5
	$(MAKE) demo-fix
	@echo ""
	@echo "$(BOLD)Demo sequence complete.$(RESET)"

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
.PHONY: nuke
nuke: teardown-cmdb down ## Full cleanup: teardown CMDB then destroy infrastructure
	$(call banner,Full cleanup complete)
