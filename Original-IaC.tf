terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
  }
  required_version = ">= 1.3.0"
}

###########################
## Data Sources
###########################
data "aws_availability_zones" "available" {
  state = "available"
}

###########################
## Variables
###########################
variable "aws_region" {
  type        = string
  description = "The region in which the resources will be created"
  default     = null
}

variable "aws_profile" {
  description = "AWS profile to use"
  type        = string
  default     = null
}

variable "aws_role_arn" {
  description = "AWS ROLE ARN"
  type        = string
  default     = null
}

variable "aws_external_id" {
  description = "AWS External ID"
  type        = string
  default     = null
}

variable "db_name" {
  type        = string
  description = "Database name"
  default     = "saladapi_db"
}

variable "db_username" {
  type        = string
  description = "Username for the database"
  default     = "saladapi_db_admin"
}

###########################
## Providers
###########################
provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  dynamic "assume_role" {
    for_each = var.aws_role_arn != null ? [1] : []
    content {
      role_arn    = var.aws_role_arn
      external_id = var.aws_external_id
    }
  }
}

###########################
## Random / Locals / Secrets
###########################
resource "random_string" "secret_suffix" {
  length  = 4
  special = false
  upper   = false
  lower   = true
  numeric = false
}

resource "random_password" "db_pw" {
  length  = 16
  special = true
  override_special = "!*()-_="
}

locals {
  service_name = "saladapi-${random_string.secret_suffix.result}"
  db_pw_secret_name = "saladapi_db_pw-${random_string.secret_suffix.result}"
  db_password = random_password.db_pw.result
  middleware_db_password = local.db_password
}

###########################
###### VPC 
###########################
resource "aws_vpc" "saladapi_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "saladapi-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.saladapi_vpc.id
  tags = {
    Name = "saladapi-igw"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.saladapi_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = {
    Name = "public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.saladapi_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags = {
    Name = "public-b"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.saladapi_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.saladapi_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "private-b"
  }
}

###########################
###### NAT 
###########################
## Use a single NAT Gateway (and EIP) instead of two to reduce hourly and data processing costs.
resource "aws_eip" "nat_eip_a" {
  vpc = true
  tags = {
    Name = "saladapi-nat-eip-a"
  }
}

resource "aws_nat_gateway" "nat_gateway_a" {
  allocation_id = aws_eip.nat_eip_a.id
  subnet_id     = aws_subnet.public_a.id
  tags = {
    Name = "saladapi-nat-a"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.saladapi_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public_a_association" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_b_association" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.saladapi_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway_a.id
  }

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private_a_association" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_b_association" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_route_table.id
}

###########################
###### Secret Manager 
###########################
resource "aws_secretsmanager_secret" "saladapi_db_pw_secret" {
  name                     = local.db_pw_secret_name
  recovery_window_in_days  = 0
  tags = {
    Name = "saladapi-db-pw"
  }
}

resource "aws_secretsmanager_secret_version" "saladapi_db_pw_version" {
  secret_id     = aws_secretsmanager_secret.saladapi_db_pw_secret.id
  secret_string = local.middleware_db_password
}

###########################
###### ECS 
###########################
resource "aws_security_group" "ecs_task_sg" {
  name        = "saladapi_ecs_task_sg"
  description = "Allow traffic from ALB"
  vpc_id      = aws_vpc.saladapi_vpc.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.saladapi_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "saladapi-ecs-task-sg"
  }
}

resource "aws_security_group" "saladapi_alb_sg" {
  name        = "saladapi_alb_sg"
  description = "Allow HTTP traffic"
  vpc_id      = aws_vpc.saladapi_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "saladapi-alb-sg"
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "saladapi_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect    = "Allow"
        Sid       = ""
      }
    ]
  })

  tags = {
    Name = "saladapi-ecs-exec-role"
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_policy" {
  name = "ecs-task-execution-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Effect    = "Allow"
        Resource  = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "ecs_secrets_access_policy" {
  name        = "saladapi_secrets_access_policy"
  description = "Allow ECS tasks to access Secrets Manager"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.saladapi_db_pw_secret.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_secrets_access_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_access_policy.arn
}

###########################
## ECS Task Definition cost optimizations
###########################
## Reduce CPU and memory to the minimum supported for this workload to reduce Fargate costs.
resource "aws_ecs_task_definition" "saladapi_ecs_task_definition" {
  family                   = "saladapi_task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  cpu    = "256"
  memory = "512"

  container_definitions = jsonencode([
    {
      name      = "saladapi_container"
      image     = "ghcr.io/serverlesssalad/kotlin-spring-postgres-demo-app:latest"
      portMappings = [{
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
      }]
      environment = [
        {
          name  = "DB_URL"
          value = "jdbc:postgresql://${aws_db_instance.saladapi_postgres_cluster.endpoint}/${var.db_name}"
        },
        {
          name  = "DB_USERNAME"
          value = var.db_username
        }
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = aws_secretsmanager_secret.saladapi_db_pw_secret.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_log_group.name
          "awslogs-stream-prefix" = "ecs"
          "awslogs-region"        = var.aws_region
        }
      }
    }
  ])
}

resource "aws_ecs_cluster" "main" {
  name = "saladapi_cluster"
}

###########################
## ECS Service cost optimizations
###########################
## Use FARGATE_SPOT capacity provider to run tasks on spot Fargate capacity (lower cost).
## Remove explicit launch_type to let capacity provider strategy take precedence.
resource "aws_ecs_service" "saladapi_ecs_service" {
  name            = "saladapi_service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.saladapi_ecs_task_definition.id
  desired_count   = 1
  wait_for_steady_state = true

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs_task_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api_tg.arn
    container_name   = "saladapi_container"
    container_port   = 8080
  }

  tags = {
    Name = "saladapi-ecs-service"
  }
}

###########################
###### Middleware (RDS)
###########################
resource "aws_security_group" "db_sg" {
  name        = "saladapi_db_sg"
  description = "Allow access to the database"
  vpc_id      = aws_vpc.saladapi_vpc.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = [aws_security_group.ecs_task_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "saladapi-db-sg"
  }
}

resource "aws_db_subnet_group" "saladapi_subnet_group" {
  name       = "saladapi_db_subnet_group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags = {
    Name = "saladapi-db-subnet-group"
  }
}

###########################
## RDS cost considerations
###########################
## Keep a small burstable instance (db.t3.micro) and minimal storage to reduce RDS costs.
resource "aws_db_instance" "saladapi_postgres_cluster" {
  identifier               = "saladapi-postgres-db"
  engine                   = "postgres"
  instance_class           = "db.t3.micro"
  allocated_storage        = 20
  username                 = var.db_username
  password                 = local.middleware_db_password
  db_name                  = var.db_name
  vpc_security_group_ids   = [aws_security_group.db_sg.id]
  db_subnet_group_name     = aws_db_subnet_group.saladapi_subnet_group.name
  skip_final_snapshot      = true
  publicly_accessible      = false
  tags = {
    Name = "saladapi-postgres"
  }
}

###########################
###### CloudWatch 
###########################
## Keep retention short to reduce log storage costs.
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/saladapi-app-log-group"
  retention_in_days = 7
  tags = {
    Name = "saladapi-logs"
  }
}

###########################
###### ALB 
###########################
resource "aws_lb" "app_lb" {
  name               = "saladapi-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.saladapi_alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags = {
    Name = "saladapi-alb"
  }
}

resource "aws_lb_target_group" "api_tg" {
  name        = "saladapi-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.saladapi_vpc.id
  target_type = "ip"

  health_check {
    path     = "/health"
    interval = 60
    timeout  = 30
    matcher  = "200"
  }

  tags = {
    Name = "saladapi-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.api_tg.arn
  }
}

###########################
###### Outputs
###########################
output "load_balancer_url" {
  value = aws_lb.app_lb.dns_name
}

output "db_endpoint" {
  value = aws_db_instance.saladapi_postgres_cluster.endpoint
  description = "Internal DB endpoint"
}