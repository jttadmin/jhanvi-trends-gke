Each folder is a Terraform root for one environment. Run commands from inside it:

    cd envs/dev && terraform init && terraform plan

Settings live in main.tf (committed). Secrets come from TF_VAR_* env vars.
