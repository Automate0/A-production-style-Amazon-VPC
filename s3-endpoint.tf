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

output "s3_gateway_endpoint_id" {
  description = "ID of the Amazon S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}