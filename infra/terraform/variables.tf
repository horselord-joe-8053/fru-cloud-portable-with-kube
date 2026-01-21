variable "region" { type = string }
variable "cluster_name" { type = string }
variable "project_id" { type = string }
variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}
variable "node_desired" {
  type    = number
  default = 2
}
variable "node_min" {
  type    = number
  default = 1
}
variable "node_max" {
  type    = number
  default = 3
}
