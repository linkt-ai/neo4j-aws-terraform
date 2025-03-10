locals {
    ubuntu_2404_x86_ami = "ami-0cb91c7de36eed2cb"
}

resource "aws_instance" "neo4j_instance" {
  count = var.node_count

  ami   = local.ubuntu_2404_x86_ami

  instance_type = var.instance_type
  key_name      = var.key_pair_name

  subnet_id = element(var.private_subnet_ids, count.index % 3)
  vpc_security_group_ids = ["${aws_security_group.neo4j_sg.id}"]
  iam_instance_profile = aws_iam_instance_profile.neo4j_instance_profile.name
  depends_on           = [aws_lb.neo4j_lb]

  user_data = templatefile(
    "${path.module}/neo4j.tftpl",
    {
      neo4j_password = var.neo4j_password
    }
  )

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