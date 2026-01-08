output "vpc_id" {
  description = "ID of the default VPC"
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "List of subnet IDs in the default VPC"
  value       = data.aws_subnets.default.ids
}

output "first_subnet_id" {
  description = "First subnet ID (convenience output for single-instance deployments)"
  value       = data.aws_subnets.default.ids[0]
}
