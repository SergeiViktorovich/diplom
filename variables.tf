variable "token" {}
variable "cloud_id" {}
variable "folder_id" {}
# variable "subnet_id" {}
variable "instance_count" {
  default = 1
}

# export YC_TOKEN=$(yc iam create-token)
# export YC_CLOUD_ID=$(yc config get cloud-id)
# export YC_FOLDER_ID=$(yc config get folder-id)