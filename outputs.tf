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