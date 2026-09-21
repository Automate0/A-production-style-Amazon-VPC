variable "aws_region" {
  type        = string
  description = "AWS Region for the network lab."
  default     = "us-east-1"
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