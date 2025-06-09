resource "aws_instance" "prj-vm" {
  ami                    = var.ami_value
  instance_type          = var.instance_type
  count                  = 1
  subnet_id              = var.subnet_id_value
  key_name               = var.key_name  # Use the existing key pair name here
  vpc_security_group_ids = [var.security_group_value]

  associate_public_ip_address = true

  tags = {
    Name = "artifactory-${count.index}"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum clean metadata
              yum install -y epel-release
              yum install -y ansible python3
              EOF
}

resource "tls_private_key" "rsa_4096" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key_pair" {
  key_name   = var.key_name
  public_key = tls_private_key.rsa_4096.public_key_openssh
}

resource "local_file" "private_key" {
  content              = tls_private_key.rsa_4096.private_key_pem
  filename             = var.key_name
  file_permission      = "0600" # 👈 Secure permissions
  directory_permission = "0700"
}

resource "null_resource" "wait_for_ssh" {
  depends_on = [aws_instance.prj-vm]

  provisioner "local-exec" {
    command = <<EOT
IP=${aws_instance.prj-vm[0].public_ip}
ATTEMPT=1
MAX_ATTEMPTS=30
while ! ssh -i ./${var.key_name} -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$IP 'exit' 2>/dev/null; do
  echo "[$ATTEMPT/$MAX_ATTEMPTS] Waiting for SSH on $IP..."
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: Timed out waiting for SSH."
    exit 1
  fi
  ATTEMPT=$((ATTEMPT+1))
  sleep 5
done
EOT
  }
}


resource "null_resource" "generate_inventory" {
  depends_on = [aws_instance.prj-vm]

  provisioner "local-exec" {
    command = <<EOT
echo "!!!!!Generating inventory file!!!!!"
chmod 600 ./${var.key_name}

# Ensure inventory directory exists
mkdir -p ansible/inventory

# Prepare host entry
HOST_ENTRY="${aws_instance.prj-vm[0].public_ip} ansible_user=${var.ansible_user} ansible_ssh_private_key_file=./${var.key_name}"

# Check if the host is already in the file
if ! grep -q "${aws_instance.prj-vm[0].public_ip}" ansible/inventory/hosts 2>/dev/null; then
  if ! grep -q "^\[artifactory\]" ansible/inventory/hosts 2>/dev/null; then
    echo "[artifactory]" >> ansible/inventory/hosts
  fi
  echo "$HOST_ENTRY" > ansible/inventory/hosts
  echo "Appended host: $HOST_ENTRY"
else
  echo "Host already exists in inventory."
fi

echo "Current directory: $(pwd)"
echo "!!!!!!DONE Generating inventory file!!!!!"
EOT
  }
}


resource "null_resource" "run_artifactory_setup_playbook" {
  depends_on = [
    null_resource.wait_for_ssh,
    aws_instance.prj-vm,
    null_resource.generate_inventory
  ]

  triggers = {
    playbook_hash = filemd5("${path.root}/ansible/site.yml")
    roles_hash    = filemd5("${path.root}/ansible/roles/artifactory/tasks/main.yml")
  }

  provisioner "local-exec" {
    command = <<EOT
cd ${path.root}
echo "Using key: ${path.root}/${var.key_name}"
echo "Trying to SSH into: ${aws_instance.prj-vm[0].public_ip}"
chmod 600 ${path.root}/${var.key_name}

echo "Running Ansible playbook..."

ansible-playbook ${path.root}/ansible/site.yml \
  -i ${path.root}/ansible/inventory/hosts \
  --ssh-extra-args='-o StrictHostKeyChecking=no -o ConnectTimeout=5'

EOT
  }
}
