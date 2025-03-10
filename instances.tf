# Get available AZs for the specified region
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "region-name"
    values = [var.target_region]
  }
}

locals {
    ubuntu_2404_x86_ami = "ami-0cb91c7de36eed2cb"
    
    # Dynamically use the first 3 available AZs in the specified region
    availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
    
    neo4j_user_data = <<-EOT
#!/bin/bash -x

# --- STEP 1: Install JDK ---
# Update packages
sudo apt-get update

# Download JDK 21 instead of 23
wget https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.deb

# Run the installer
sudo dpkg -i jdk-21_linux-x64_bin.deb

# --- STEP 2: Install Neo4j ---

# Add the Neo4j repository - Fix the GPG key import
sudo mkdir -p /etc/apt/keyrings
wget -O - https://debian.neo4j.com/neotechnology.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/neotechnology.gpg
echo 'deb [signed-by=/etc/apt/keyrings/neotechnology.gpg] https://debian.neo4j.com stable latest' | sudo tee /etc/apt/sources.list.d/neo4j.list
sudo apt-get update -y

# Install Neo4j
sudo apt-get install neo4j=1:2025.02.0 -y

# --- STEP 3: Configure Neo4j to listen on all interfaces ---
# Set Neo4j to listen on all network interfaces
sudo sed -i 's/#server.default_listen_address=0.0.0.0/server.default_listen_address=0.0.0.0/' /etc/neo4j/neo4j.conf

# Configure specific connectors if needed
sudo sed -i 's/#server.bolt.listen_address=:7687/server.bolt.listen_address=0.0.0.0:7687/' /etc/neo4j/neo4j.conf
sudo sed -i 's/#server.http.listen_address=:7474/server.http.listen_address=0.0.0.0:7474/' /etc/neo4j/neo4j.conf

# --- STEP 4: Mount EBS volume for persistent storage ---
# Wait for the EBS volume to be attached (improved detection)
echo "Waiting for EBS volume to be attached..."
while ! lsblk | grep -q 'nvme1n1\|xvdf'; do
  sleep 5
done

# Determine the device name based on what's available
DEVICE_NAME=""
if lsblk | grep -q nvme1n1; then
  DEVICE_NAME="/dev/nvme1n1"
elif lsblk | grep -q xvdf; then
  DEVICE_NAME="/dev/xvdf"
else
  echo "Could not find the expected EBS volume"
  exit 1
fi

echo "Found EBS volume at $DEVICE_NAME"

# Create a mount point for Neo4j data
NEO4J_DATA_DIR="/var/lib/neo4j/data"
sudo mkdir -p $NEO4J_DATA_DIR

# Check if the volume is already formatted
if ! sudo file -s $DEVICE_NAME | grep -q ext4; then
  echo "Formatting EBS volume with ext4"
  # Format the volume if not already formatted
  sudo mkfs -t ext4 $DEVICE_NAME
fi

# Mount the volume
echo "Mounting EBS volume to $NEO4J_DATA_DIR"
sudo mount $DEVICE_NAME $NEO4J_DATA_DIR

# Add to fstab to ensure the mount persists across reboots
echo "$DEVICE_NAME $NEO4J_DATA_DIR ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab

# Set proper ownership for Neo4j
sudo chown -R neo4j:neo4j $NEO4J_DATA_DIR

# Configure Neo4j to use the mounted volume for data
sudo sed -i "s|#server.directories.data=data|server.directories.data=$NEO4J_DATA_DIR|" /etc/neo4j/neo4j.conf

# Set the password for the database
sudo neo4j-admin dbms set-initial-password "${var.neo4j_password}"

# Restart Neo4j to apply changes
sudo systemctl enable neo4j
sudo systemctl restart neo4j

# Verify the mount and configuration
echo "Verifying mount point:"
df -h | grep $NEO4J_DATA_DIR
echo "Neo4j data directory configuration:"
grep "server.directories.data" /etc/neo4j/neo4j.conf
EOT
}

resource "aws_instance" "neo4j_instance" {
  count = var.node_count

  ami   = local.ubuntu_2404_x86_ami
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  # Use a consistent AZ for each instance index
  availability_zone = element(local.availability_zones, count.index % length(local.availability_zones))
  
  subnet_id = element(var.private_subnet_ids, count.index % length(var.private_subnet_ids))
  vpc_security_group_ids = ["${aws_security_group.neo4j_sg.id}"]
  iam_instance_profile = aws_iam_instance_profile.neo4j_instance_profile.name
  depends_on           = [aws_lb.neo4j_lb]

  user_data = local.neo4j_user_data

  tags = {
    "Name"      = "${var.env_prefix}-neo4j-${count.index}"
    "Terraform" = true
  }

  // only set to true when developing/debugging.  tf default = false
  user_data_replace_on_change = false

  // don't force-recreate instance if only user data changes
  lifecycle {
    ignore_changes = [user_data]
  }
}

# Create EBS volumes for Neo4j data storage
resource "aws_ebs_volume" "neo4j_data" {
  count             = var.node_count
  # Use the same AZ pattern as the instance
  availability_zone = element(local.availability_zones, count.index % length(local.availability_zones))
  size              = 100
  type              = "gp3"
  
  tags = {
    Name        = "${var.env_prefix}-neo4j-data-${count.index}"
    Terraform   = true
  }

  # Add lifecycle policy to prevent recreation
  lifecycle {
    prevent_destroy = true
  }
}

# Attach EBS volumes to Neo4j instances
resource "aws_volume_attachment" "neo4j_data_attachment" {
  count        = var.node_count
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.neo4j_data[count.index].id
  instance_id  = aws_instance.neo4j_instance[count.index].id
  
  # Make sure the attachment is recreated if the instance is recreated
  skip_destroy = true
}