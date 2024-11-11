terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.84"  # Версия может отличаться
    }
  }
}

# Создаем сеть
resource "yandex_vpc_network" "network" {
  name = "web-network"
}

# Публичная подсеть для бастион-хоста
resource "yandex_vpc_subnet" "public_subnet" {
  name           = "public-subnet"
  zone           = "ru-central1-a"  # Зона для бастион-хоста
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.0.1.0/24"]
}

# Добавляем NAT gateway
resource "yandex_vpc_gateway" "nat_gateway" {
  name             = "nat-gateway"
  network_id       = yandex_vpc_network.network.id
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

# Приватная подсеть для зоны ru-central1-a
resource "yandex_vpc_subnet" "subnet_a" {
  name           = "web-subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.0.2.0/24"]
  route_table_id = yandex_vpc_route_table.nat_route_table.id  # Таблица маршрутов для NAT
}

# Приватная подсеть для зоны ru-central1-b
resource "yandex_vpc_subnet" "subnet_b" {
  name           = "web-subnet-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.0.3.0/24"]
  route_table_id = yandex_vpc_route_table.nat_route_table.id  # Таблица маршрутов для NAT
}

resource "yandex_compute_instance" "bastion_host" {
  name     = "bastion-host"
  hostname = "bastion-host"
  zone     = "ru-central1-a"

  resources {
    cores         = 2
    core_fraction = 20
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh"  # Ubuntu 22.04
      size     = 10
      type     = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true  # Прерываемая ВМ
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.public_subnet.id
    nat       = true  # Нужен для подключения к интернету
  }

  metadata = {
    ssh-keys = "user:${file("/home/user/.ssh/id_ed25519.pub")}"
  }
}

# Виртуальная машина в зоне ru-central1-a
resource "yandex_compute_instance" "web_server_1" {
  name     = "web-server-1"
  hostname = "web-server-1"
  zone     = "ru-central1-a"

  resources {
    cores         = 2               # 2 ядра
    core_fraction = 20              # Прерываемая ВМ с 20% CPU
    memory        = 2               # 2 Гб памяти
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh"  # Ubuntu 22.04
      size     = 10  # Диск 10 Гб (HDD)
      type     = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true  # Прерываемая ВМ
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_a.id
    nat       = false
  }

  metadata = {
    ssh-keys = "user:${file("/home/user/.ssh/id_ed25519.pub")}"
  }
}

# Виртуальная машина в зоне ru-central1-b
resource "yandex_compute_instance" "web_server_2" {
  name     = "web-server-2"
  hostname = "web-server-2"
  zone     = "ru-central1-b"

  resources {
    cores         = 2               # 2 ядра
    core_fraction = 20              # Прерываемая ВМ с 20% CPU
    memory        = 2               # 2 Гб памяти
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh"  # Ubuntu 22.04
      size     = 10  # Диск 10 Гб (HDD)
      type     = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true  # Прерываемая ВМ
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_b.id
    nat       = false
  }

  metadata = {
    ssh-keys = "user:${file("/home/user/.ssh/id_ed25519.pub")}"
  }
}

# Создаем целевую группу с указанием IP-адресов
resource "yandex_alb_target_group" "web-target-groups" {
  name = "web-target-groups"

  target {
    subnet_id  = yandex_vpc_subnet.subnet_a.id
    ip_address = yandex_compute_instance.web_server_1.network_interface.0.ip_address
  }

  target {
    subnet_id  = yandex_vpc_subnet.subnet_b.id
    ip_address = yandex_compute_instance.web_server_2.network_interface.0.ip_address
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
        host               = "web-server-1"   # Адрес хоста для web-server-1
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
        host               = "web-server-2"   # Адрес хоста для web-server-2
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
      subnet_id = yandex_vpc_subnet.subnet_a.id
    }
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.subnet_b.id
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
  value = yandex_alb_target_group.web-target-groups.id
}

output "backend_group_id" {
  value = yandex_alb_backend_group.web-backend-group.id
}

output "load_balancer_id" {
  value = yandex_alb_load_balancer.web-balancer.id
}
