# One Application Load Balancer for both apps, with path-based routing:
#   /api/* and /health  -> backend  (port 8000)
#   everything else     -> frontend (port 8080)
# Frontend and API share one origin, so the browser needs no cross-origin calls.
#
# The ALB listens on HTTP only and accepts traffic only from CloudFront (AWS-managed
# prefix list). CloudFront terminates HTTPS with its default *.cloudfront.net certificate.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Load balancer: HTTP from CloudFront only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront edge locations"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  for_each = var.apps

  security_group_id            = aws_security_group.alb.id
  description                  = "To the ${each.key} tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# Used by the ECS tasks: reachable only from the load balancer.
resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "ECS tasks: app ports from the load balancer only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  for_each = var.apps

  security_group_id            = aws_security_group.tasks.id
  description                  = "${each.key} port from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# Tasks need outbound HTTPS to pull images from ECR and to send logs to CloudWatch.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to AWS APIs (ECR, CloudWatch Logs)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_lb" "main" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  drop_invalid_header_fields = true
  idle_timeout               = 60
}

resource "aws_lb_target_group" "app" {
  for_each = var.apps

  name        = "${var.name}-${each.value.short_name}"
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "ip" # Fargate tasks register by IP
  vpc_id      = var.vpc_id

  # Short drain: these apps are stateless, so deployments finish faster.
  deregistration_delay = 15

  health_check {
    path                = each.value.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["frontend"].arn
  }
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["backend"].arn
  }

  condition {
    path_pattern {
      values = var.backend_paths
    }
  }
}
