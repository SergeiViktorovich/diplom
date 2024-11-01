terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.84"  # Версия может отличаться
    }
  }
}

provider "yandex" {
  token     = var.token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

resource "yandex_compute_instance" "vm" {
  count = var.instance_count
  name  = "web-${count.index}"
  hostname = "web-${count.index}"

  resources {
    cores  = 2                      # 2 ядра
    core_fraction = 20              # Прерываемая ВМ с 20% CPU
    memory = 2                      # 2 Гб памяти
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh"  # Ubuntu 22.04
      size = 10  # Диск 10 Гб (HDD)
      type = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true  # Прерываемая ВМ
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "user:${file("~/.ssh/id_ed25519.pub")}"
  }
}

resource "yandex_compute_instance" "vm" {
  count = var.instance_count
  name  = "web-${count.index}"
  hostname = "web-${count.index}"

  resources {
    cores  = 2                      # 2 ядра
    core_fraction = 20              # Прерываемая ВМ с 20% CPU
    memory = 2                      # 2 Гб памяти
  }

  boot_disk {
    initialize_params {
      image_id = "fd8p4jt9v2pfq4ol9jqh"  # Ubuntu 22.04
      size = 10  # Диск 10 Гб (HDD)
      type = "network-hdd"
    }
  }

  scheduling_policy {
    preemptible = true  # Прерываемая ВМ
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "user:${file("~/.ssh/id_ed25519.pub")}"
  }
}

resource "yandex_vpc_network" "network" {
  name = "web-network"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "web-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.0.0.0/24"]
}

output "vm_hostnames" {
  value = [for vm in yandex_compute_instance.vm : "${vm.hostname}.ru-central1.internal"]
}