package cloudarmor.waf

import rego.v1

# Draft technical hypothesis only. Confirm the governing control and wording
# before using this rule for an audit conclusion.

deny contains msg if {
	not input.target.internetFacing
	msg := "target is not confirmed as internet-facing"
}

deny contains msg if {
	not attached_security_policy
	msg := "backend service is not attached to the security policy under evaluation"
}

deny contains msg if {
	not backend_service_request_logging_enabled
	msg := "backend service request logging is not enabled"
}

deny contains msg if {
	not backend_service_requests_sampled
	msg := "backend service request logging sample rate is zero, missing, or invalid"
}

deny contains msg if {
	not active_preconfigured_waf_rule
	msg := "no active, non-preview preconfigured WAF rule with an enforcement action was found"
}

attached_security_policy if {
	input.backendService.securityPolicy != ""
	input.securityPolicy.selfLink != ""
	input.backendService.securityPolicy == input.securityPolicy.selfLink
}

backend_service_request_logging_enabled if {
	input.backendService.logConfig.enable == true
}

backend_service_requests_sampled if {
	sample_rate := input.backendService.logConfig.sampleRate
	is_number(sample_rate)
	sample_rate > 0
	sample_rate <= 1
}

active_preconfigured_waf_rule if {
	some i
	rule := input.securityPolicy.rules[i]
	object.get(rule, "preview", false) == false
	enforcing_action(rule.action)
	match := object.get(rule, "match", {})
	expr := object.get(match, "expr", {})
	expression := object.get(expr, "expression", "")
	contains(expression, "evaluatePreconfiguredWaf(")
}

enforcing_action(action) if {
	startswith(action, "deny(")
}

enforcing_action(action) if {
	action == "throttle"
}

enforcing_action(action) if {
	action == "rate_based_ban"
}
