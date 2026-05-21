from dataclasses import dataclass
from typing import Any, Dict

# Product Domain
@dataclass
class ProductCreated: payload: Dict[str, Any]
@dataclass
class LotCreated: payload: Dict[str, Any]
@dataclass
class BOMMapped: payload: Dict[str, Any]

# Supplier Domain
@dataclass
class SupplierInvited: payload: Dict[str, Any]
@dataclass
class SupplierConnected: payload: Dict[str, Any]
@dataclass
class SupplierStatusChanged: payload: Dict[str, Any]

# Submission Domain
@dataclass
class SubmissionRequested: payload: Dict[str, Any]
@dataclass
class SubmissionStarted: payload: Dict[str, Any]
@dataclass
class SubmissionCompleted: payload: Dict[str, Any]
@dataclass
class SubmissionRejected: payload: Dict[str, Any]
@dataclass
class SubmissionApproved: payload: Dict[str, Any]

# Verification Domain
@dataclass
class VerificationStarted: payload: Dict[str, Any]
@dataclass
class VerificationFailed: payload: Dict[str, Any]
@dataclass
class VerificationCompleted: payload: Dict[str, Any]

# Risk Domain
@dataclass
class RiskDetected: payload: Dict[str, Any]
@dataclass
class RiskEscalated: payload: Dict[str, Any]
@dataclass
class RiskResolved: payload: Dict[str, Any]

# HITL Domain
@dataclass
class HITLRequested: payload: Dict[str, Any]
@dataclass
class HITLAssigned: payload: Dict[str, Any]
@dataclass
class HITLApproved: payload: Dict[str, Any]
@dataclass
class HITLRejected: payload: Dict[str, Any]

# DPP Domain
@dataclass
class DPPReadinessUpdated: payload: Dict[str, Any]
@dataclass
class DPPIssued: payload: Dict[str, Any]

# Audit Domain
@dataclass
class AuditStepRecorded: payload: Dict[str, Any]
@dataclass
class GapAnalysisCompleted: payload: Dict[str, Any]