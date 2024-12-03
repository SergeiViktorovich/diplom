terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.84, < 1.0"
    }
  }
}

provider "yandex" {
  token     = var.yc_token        # Токен доступа
  cloud_id  = var.cloud_id        # Идентификатор облака
  folder_id = var.folder_id       # Идентификатор каталога
}

# Создаем сеть
resource "yandex_vpc_network" "network" {
  name = "web-network"
}

# Переменные для подсетей
variable "subnets" {
  description = "Параметры подсетей"
  type = map(object({
    cidr_block = string
    zone       = string
    is_private = bool
  }))
  default = {
    "public-subnet" = {
      cidr_block = "10.0.1.0/24"
      zone       = "ru-central1-a"
      is_private = false
    }
    "private-subnet-a" = {
      cidr_block = "10.0.2.0/24"
      zone       = "ru-central1-a"
      is_private = true
    }
    "private-subnet-b" = {
      cidr_block = "10.0.3.0/24"
      zone       = "ru-central1-b"
      is_private = true
    }
  }
}

# Локальные переменные для разделения подсетей
locals {
  private_subnets = { for k, v in var.subnets : k => v if v.is_private }
  public_subnets  = { for k, v in var.subnets : k => v if !v.is_private }
}

# Создание NAT Gateway
resource "yandex_vpc_gateway" "nat_gateway" {
  name = "nat-gateway"
  shared_egress_gateway {}
}

# Таблица маршрутов для приватных подсетей
resource "yandex_vpc_route_table" "nat_route_table" {
  for_each   = local.private_subnets
  name       = "nat-route-table-${each.key}"
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# Создание подсетей
resource "yandex_vpc_subnet" "subnets" {
  for_each      = var.subnets
  name          = each.key
  v4_cidr_blocks = [each.value.cidr_block]
  zone          = each.value.zone
  network_id    = yandex_vpc_network.network.id
  route_table_id = each.value.is_private ? yandex_vpc_route_table.nat_route_table[each.key].id : null
}

# Переменные для виртуальных машин
variable "instances" {
  description = "Параметры виртуальных машин"
  type = map(object({
    name       = string
    zone       = string
    subnet_key = string
    cores      = number
    memory     = number
    nat        = bool
  }))
  default = {
    "zabbix-server" = {
      name       = "zabbix-server"
      zone       = "ru-central1-a"
      subnet_key = "public-subnet"
      cores      = 2
      memory     = 2
      nat        = true
    }
    "bastion-host" = {
      name       = "bastion-host"
      zone       = "ru-central1-a"
      subnet_key = "public-subnet"
      cores      = 2
      memory     = 2
      nat        = true
    }
    "web-server-1" = {
      name       = "web-server-1"
      zone       = "ru-central1-a"
      subnet_key = "private-subnet-a"
      cores      = 2
      memory     = 2
      nat        = false
    }
    "web-server-2" = {
      name       = "web-server-2"
      zone       = "ru-central1-b"
      subnet_key = "private-subnet-b"
      cores      = 2
      memory     = 2
      nat        = false
    }
  }
}

# Создание виртуальных машин
resource "yandex_compute_instance" "instances" {
  for_each = var.instances

  name     = each.value.name
  hostname = each.value.name
  zone     = each.value.zone

  resources {
    cores         = each.value.cores
    core_fraction = 20
    memory        = each.value.memory
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh" # Ubuntu 22.04
      size     = 10
      type     = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnets[each.value.subnet_key].id
    nat       = each.value.nat
  }

  metadata = {
    ssh-keys = "user:${file(var.ssh_public_key_path)}"
  }
}

# Создание целевой группы
resource "yandex_alb_target_group" "web-target-groups" {
  name = "web-target-groups"

  dynamic "target" {
    for_each = toset(["web-server-1", "web-server-2"])
    content {
      subnet_id  = yandex_vpc_subnet.subnets[var.instances[target.value].subnet_key].id
      ip_address = yandex_compute_instance.instances[target.value].network_interface.0.ip_address
    }
  }
}

# Создаем группу бэкендов
resource "yandex_alb_backend_group" "web-backend-group" {
  name = "web-backend-group"  

  http_backend {
    name                   = "http-backend"
    weight                 = 1
    port                   = 80
    target_group_ids       = [yandex_alb_target_group.web-target-groups.id]  # Идентификатор целевой группы
    
    load_balancing_config {
      panic_threshold      = 90
    }
   
    healthcheck {
      timeout              = "10s"
      interval             = "2s"
      healthy_threshold    = 10
      unhealthy_threshold  = 15
      http_healthcheck {
        path               = "/"
        host               = 
      }
    }
  }
}

# Создаем HTTP роутер
resource "yandex_alb_http_router" "tf-router" {
  name = "my-http-router"  # Имя HTTP роутера
  labels = {
    tf-label    = "tf-label-value"
    empty-label = ""
  }
}

# Создаем виртуальный хост
resource "yandex_alb_virtual_host" "my-virtual-host" {
  for_each       = yandex_alb_backend_group.web-backend-group  # Для каждого бэкенда создаем виртуальный хост
  name           = "my-virtual-host-${each.key}"  # Имя виртуального хоста
  http_router_id = yandex_alb_http_router.tf-router.id

  route {
    name                  = "root-route"  # Имя маршрута
    http_route {
      http_route_action {
        backend_group_id  = each.value.id  # Идентификатор группы бэкендов
        timeout           = "60s"  # Таймаут
      }
    }
  }

  route_options {
    # security_profile_id   = "<идентификатор_профиля_безопасности>"
  }
}

# Создаем L7-балансировщик
resource "yandex_alb_load_balancer" "web-balancer" {
  name        = "web-l7-balancer"
  network_id  = yandex_vpc_network.network.id

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.subnets["private-subnet-a"].id
    }
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.subnets["private-subnet-b"].id
    }
  }

  listener {
    name = "http-listener"
    endpoint {
      address {
        external_ipv4_address {
          # Параметры внешнего адреса
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.tf-router.id
      }
    }
  }
  
  # Настройки логирования (если не нужно, можно закомментировать)
  # log_options {
  #   log_group_id = "<идентификатор_лог-группы>"
  #   discard_rule {
  #     http_codes          = ["404"]
  #     http_code_intervals = ["5xx"]
  #     discard_percent     = 0.1
  #   }
  # }
}

output "target_group_id" {
  description = "ID целевой группы веб-серверов"
  value = yandex_alb_target_group.web-target-groups.id
}

output "backend_group_id" {
  description = "ID бекенд группы веб-серверов"
  value = [for group in yandex_alb_backend_group.web-backend-group : group.id]
}

output "load_balancer_id" {
  description = "ID балансировщика"
  value = yandex_alb_load_balancer.web-balancer.id
}

output "zabbix_server_ip" {
  description = "IP адрес Zabbix Server"
  value       = yandex_compute_instance.instances["zabbix-server"].network_interface.0.ip_address
}