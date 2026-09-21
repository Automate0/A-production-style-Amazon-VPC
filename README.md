# Two-AZ VPC with Terraform

A production-style Amazon VPC deployed across two Availability Zones using Terraform. The network gives internet-facing services a public path through an internet gateway, while private workloads reach the internet through controlled, zone-local NAT egress and never accept unsolicited inbound traffic.

Built as a hands-on infrastructure-as-code project to demonstrate reusable, multi-AZ AWS networking foundations for future Amazon EC2, Amazon EKS, and Amazon RDS workloads.

## Architecture

```
                          Internet
                             |
                     Internet Gateway
                             |
                    Public Route Table (0.0.0.0/0 -> IGW)
                    /                      \
        Public Subnet A (AZ-1)      Public Subnet B (AZ-2)
        10.0.0.0/24                 10.0.1.0/24
        NAT Gateway A + EIP         NAT Gateway B + EIP
             |                           |
        Private RT A                Private RT B
        (0.0.0.0/0 -> NAT A)        (0.0.0.0/0 -> NAT B)
             |                           |
        Private Subnet A (AZ-1)     Private Subnet B (AZ-2)
        10.0.10.0/24                10.0.11.0/24
             \                          /
              S3 Gateway VPC Endpoint (both private route tables)
```

VPC CIDR: `10.0.0.0/16`

| Tier | Subnet | CIDR | Availability Zone | Egress path |
|------|--------|------|-------------------|-------------|
| Public | public_a | 10.0.0.0/24 | AZ 1 | Internet Gateway |
| Public | public_b | 10.0.1.0/24 | AZ 2 | Internet Gateway |
| Private | private_a | 10.0.10.0/24 | AZ 1 | NAT Gateway A |
| Private | private_b | 10.0.11.0/24 | AZ 2 | NAT Gateway B |

## Key design decisions

- **Two Availability Zones** for resilience. The two zones are selected dynamically from the account using the `aws_availability_zones` data source, filtered to zones that do not require an explicit opt-in.
- **One NAT gateway per zone.** Each private subnet routes outbound traffic through the NAT gateway in its own AZ, so neither zone depends on the other for egress and there is no single zonal point of failure.
- **Separate route table per private subnet**, keeping each zone's egress path independent and explicit in state.
- **EKS-ready subnet tags.** Public subnets carry `kubernetes.io/role/elb = 1` and private subnets carry `kubernetes.io/role/internal-elb = 1`, so future load balancers can auto-discover the correct tier.
- **Layered security groups.** An ALB security group allows inbound HTTP from the internet, and a workload security group accepts traffic only from the ALB tier, keeping future workloads reachable exclusively through the load balancer.
- **S3 Gateway VPC Endpoint** attached to both private route tables, so private workloads can reach Amazon S3 without routing through (and paying for) the NAT gateways.

## Resources created

- 1 VPC
- 4 Subnets (2 public, 2 private)
- 1 Internet Gateway
- 2 Elastic IPs + 2 NAT Gateways
- 3 Route tables (1 shared public, 2 private) with associations and default routes
- 2 Security groups (ALB and workload) with ingress/egress rules
- 1 S3 Gateway VPC Endpoint

## Repository layout

| File | Responsibility |
|------|----------------|
| `terraform.tf` | Terraform and AWS provider version constraints |
| `providers.tf` | AWS provider configuration and default tags |
| `variables.tf` | Reusable input variables (region, project name, VPC CIDR) |
| `network.tf` | VPC, subnets, gateways, route tables, security groups |
| `outputs.tf` | Exposed deployment details (VPC ID, subnet IDs, AZs) |
| `s3-endpoint.tf` | S3 Gateway VPC Endpoint |

## Requirements

- Terraform CLI `>= 1.16.3`
- AWS provider `6.65.0` (pinned)
- AWS CLI v2, authenticated to your target account
- An AWS account (approximate run cost for this lab: ~$0.10)

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `aws_region` | AWS region to deploy into | `us-east-2` |
| `project_name` | Name prefix for all resources | `two-az-network` |
| `vpc_cidr` | IPv4 CIDR block for the VPC | `10.0.0.0/16` |

## Outputs

| Name | Description |
|------|-------------|
| `vpc_id` | ID of the created VPC |
| `availability_zones` | The two AZs the subnets span |
| `public_subnet_ids` | IDs of both public subnets |
| `private_subnet_ids` | IDs of both private subnets |
| `s3_gateway_endpoint_id` | ID of the S3 Gateway VPC Endpoint |

## Implementation

Create the five core files in an empty folder and paste in the code below. The network is built in dependency order: VPC first, then subnets, then gateways and routing, then security groups. Add `s3-endpoint.tf` last for the S3 endpoint.

### terraform.tf

Pins the Terraform CLI and AWS provider versions for reproducible runs.

```hcl
terraform {
  required_version = ">= 1.16.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.65.0"
    }
  }
}
```

### providers.tf

Configures the AWS provider and applies default tags to every supported resource.

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "lab"
      ManagedBy   = "Terraform"
      Project     = var.project_name
    }
  }
}
```

### variables.tf

Region, name prefix, and VPC address range, kept in one place.

```hcl
variable "aws_region" {
  type        = string
  description = "AWS Region for the network lab."
  default     = "us-east-2"
}

variable "project_name" {
  type        = string
  description = "Name prefix used for network resources."
  default     = "two-az-network"
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR block for the VPC."
  default     = "10.0.0.0/16"
}
```

### network.tf

The full network: zone lookup, VPC, four subnets, internet gateway, route tables and associations, NAT gateways with Elastic IPs, private default routes, and the two layered security groups.

```hcl
# Select the first two standard (no opt-in) Availability Zones in the account
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = var.project_name
  }
}

# Public subnets (one per AZ), tagged for future public load balancer discovery
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.project_name}-public-a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.project_name}-public-b"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private subnets (one per AZ), tagged for future internal load balancer discovery
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name                              = "${var.project_name}-private-a"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name                              = "${var.project_name}-private-b"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Internet gateway for the public tier
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Shared public route table with a default route to the internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet, so each AZ gets an independent egress path
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-a"
  }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-b"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# Elastic IPs for the NAT gateways
resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-b"
  }

  depends_on = [aws_internet_gateway.main]
}

# One NAT gateway per zone, each in its own public subnet
resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.allocation_id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${var.project_name}-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.allocation_id
  subnet_id     = aws_subnet.public_b.id

  tags = {
    Name = "${var.project_name}-nat-b"
  }

  depends_on = [aws_internet_gateway.main]
}

# Private default routes, each to the NAT gateway in the same AZ
resource "aws_route" "private_a_default" {
  route_table_id         = aws_route_table.private_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.a.id
}

resource "aws_route" "private_b_default" {
  route_table_id         = aws_route_table.private_b.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.b.id
}

# Security groups: public ALB tier and a workload tier reachable only from the ALB
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "Public HTTP entry point for a future load balancer"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_security_group" "workload" {
  name        = "${var.project_name}-workload"
  description = "Application traffic accepted only from the load balancer security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-workload"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow public HTTP traffic to the future load balancer"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow the future load balancer to reach targets"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "workload_from_alb" {
  security_group_id            = aws_security_group.workload.id
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "Allow application traffic only from the load balancer"
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "workload_all" {
  security_group_id = aws_security_group.workload.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow outbound traffic from future workloads"
  ip_protocol       = "-1"
}
```

### s3-endpoint.tf

An S3 Gateway VPC Endpoint attached to both private route tables, so private workloads reach S3 without a NAT gateway. Note the `service_name` uses `var.aws_region` so it always matches the deployment region (see the region-mismatch gotcha below).

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private_a.id,
    aws_route_table.private_b.id
  ]

  tags = {
    Name = "${var.project_name}-s3"
  }
}
```

### outputs.tf

Exposes the useful IDs and a readable routing summary for inspection.

```hcl
output "availability_zones" {
  description = "Availability Zones used by the network."
  value = [
    data.aws_availability_zones.available.names[0],
    data.aws_availability_zones.available.names[1]
  ]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by Availability Zone position."
  value = {
    a = aws_nat_gateway.a.id
    b = aws_nat_gateway.b.id
  }
}

output "private_subnet_ids" {
  description = "Private subnet IDs for future workloads."
  value = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]
}

output "public_subnet_ids" {
  description = "Public subnet IDs for future load balancers."
  value = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
}

output "route_table_ids" {
  description = "Public and private route table IDs."
  value = {
    public    = aws_route_table.public.id
    private_a = aws_route_table.private_a.id
    private_b = aws_route_table.private_b.id
  }
}

output "routing_summary" {
  description = "Default-route targets for each network tier."
  value = {
    public    = "0.0.0.0/0 -> ${aws_internet_gateway.main.id}"
    private_a = "0.0.0.0/0 -> ${aws_nat_gateway.a.id}"
    private_b = "0.0.0.0/0 -> ${aws_nat_gateway.b.id}"
  }
}

output "security_group_ids" {
  description = "Security-group IDs for the future load balancer and workloads."
  value = {
    alb      = aws_security_group.alb.id
    workload = aws_security_group.workload.id
  }
}

output "vpc_id" {
  description = "ID of the deployed VPC."
  value       = aws_vpc.main.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}
```

## Usage

Clone the repo and change into it:

```bash
git clone https://github.com/<your-username>/two-az-network.git
cd two-az-network
```

Confirm your AWS identity points at the intended account before applying:

```bash
aws sts get-caller-identity
```

Initialize, review, and deploy:

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Terraform pauses after the plan and only proceeds when you type `yes`.

### Inspecting the network

Capture the VPC ID and inspect the route tables to see the public default route and each private subnet's zonal NAT route:

```bash
# PowerShell
$VpcId = terraform output -raw vpc_id
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VpcId" --region us-east-2 --output table
```

```bash
# bash
VPC_ID=$(terraform output -raw vpc_id)
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region us-east-2 --output table
```

### Tearing down

To remove every resource this configuration created:

```bash
terraform destroy
```

## Gotcha: S3 Gateway Endpoint region mismatch

Gateway VPC endpoints are strictly regional, so the endpoint's `service_name` region must match the region where the VPC actually lives. A hardcoded or mismatched region produces:

```
Error: creating EC2 VPC Endpoint: InvalidParameter:
Endpoint type (Gateway) does not match available service types ([Interface]).
```

Fix it by deriving the service name from the region variable instead of hardcoding it:

```hcl
service_name = "com.amazonaws.${var.aws_region}.s3"
```

Then make sure `aws_region` matches the region your resources are deployed in, and re-run `terraform validate`, `terraform plan`, and `terraform apply`.

## What I learned

- Structuring a Terraform project into focused files (providers, variables, network, outputs) for readability and reuse.
- Using data sources to select Availability Zones dynamically rather than hardcoding them.
- Building explicit routing to make the difference between public and private traffic paths visible and inspectable.
- Designing zone-local NAT egress for resilience.
- Layering security groups so workloads are only reachable through a load balancer tier.
- Adding an S3 Gateway Endpoint to cut NAT costs, and debugging a real region-mismatch error along the way.

---

Deployed and inspected end to end with Terraform. Built by Adan Playil.
