terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.84"  # Версия может отличаться
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

# Объявляем переменную для подсетей
variable "subnets" {
  description = "Параметры подсетей"
  type = map(object({
    cidr_block = string
    zone       = string
    is_private = bool  # Флаг, указывающий на использование NAT
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

# Создаем подсети с использованием for_each
resource "yandex_vpc_subnet" "subnets" {
  for_each = var.subnets

  name           = each.key
  v4_cidr_blocks = [each.value.cidr_block]
  zone           = each.value.zone
  network_id     = yandex_vpc_network.network.id
  route_table_id = each.value.is_private ? yandex_vpc_route_table.nat_route_table.id : null
}

# Добавляем NAT gateway
resource "yandex_vpc_gateway" "nat_gateway" {
  name = "nat-gateway"
  shared_egress_gateway {}
}

# Таблица маршрутов с NAT gateway
resource "yandex_vpc_route_table" "nat_route_table" {
  name       = "nat-route-table"
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# Объявляем переменную для виртуальныйх машин
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

# Создаем ВМ с использованием for_each
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

# Создаем целевую группу с указанием IP-адресов
resource "yandex_alb_target_group" "web-target-groups" {
  name = "web-target-groups"

  target {
    subnet_id  = yandex_vpc_subnet.subnets["private-subnet-a"].id
    ip_address = yandex_compute_instance.instances["web-server-1"].network_interface.0.ip_address
  }

  target {
    subnet_id  = yandex_vpc_subnet.subnets["private-subnet-b"].id
    ip_address = yandex_compute_instance.instances["web-server-2"].network_interface.0.ip_address
  }
}

# Создаем группу бэкендов
resource "yandex_alb_backend_group" "web-backend-group" {
  name = "web-backend-group"

  session_affinity {
    connection {
      source_ip = true  # Установите режим привязки сессий по IP-адресу
    }
  }

  # Первый HTTP бэкенд для web-server-1
  http_backend {
    name                   = "backend-web-server-1"  # Имя бэкенда
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
        path               = "/"              # Путь для проверки состояния
        host               = yandex_compute_instance.instances["web-server-1"].network_interface.0.ip_address   # Адрес хоста для web-server-1
      }
    }
  }

  # Второй HTTP бэкенд для web-server-2
  http_backend {
    name                   = "backend-web-server-2"  # Имя бэкенда
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
        path               = "/"              # Путь для проверки состояния
        host               = yandex_compute_instance.instances["web-server-2"].network_interface.0.ip_address   # Адрес хоста для web-server-2
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
  name                    = "my-virtual-host"  # Имя виртуального хоста
  http_router_id          = yandex_alb_http_router.tf-router.id

  route {
    name                  = "root-route"  # Имя маршрута
    http_route {
      http_route_action {
        backend_group_id  = yandex_alb_backend_group.web-backend-group.id  # Идентификатор группы бэкендов
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
  value = yandex_alb_backend_group.web-backend-group.id
}

output "load_balancer_id" {
  description = "ID балансировщика"
  value = yandex_alb_load_balancer.web-balancer.id
}

output "zabbix_server_ip" {
  description = "IP адрес Zabbix Server"
  value       = yandex_compute_instance.instances["zabbix-server"].network_interface.0.ip_address
}