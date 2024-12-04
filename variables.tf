variable "yc_token" {
  description = "Токен доступа Yandex Cloud"
  type        = string
  sensitive   = true
  #default = ""
}

variable "cloud_id" {
  description = "Идентификатор облака"
  type        = string
  sensitive   = true
  #default = ""
}

variable "folder_id" {
  description = "Идентификатор каталога"
  type        = string
  sensitive   = true
  #default = ""
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу"
  type        = string
  #default     = ""
}
