variable "yc_token" {
  description = "Токен доступа Yandex Cloud"
  type        = string
  #default = ""
}

variable "cloud_id" {
  description = "Идентификатор облака"
  type        = string
  #default = ""
}

variable "folder_id" {
  description = "Идентификатор каталога"
  type        = string
  #default = ""
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу"
  type        = string
  #default     = ""
}
