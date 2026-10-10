enum IssueKind {
  competingLeaves,
  missingParent,
  invalidHistory,
  contentConflict,
  missingFile,
  badFile,
  oversell,
  dayOrderCollision,
  unsupportedVersion,
}

class LedgerIssue {
  const LedgerIssue(
    this.kind,
    this.message, {
    this.transactionId,
    this.recordIds = const [],
  });

  final IssueKind kind;
  final String? transactionId;
  final List<String> recordIds;

  /// Short English text for the UI; never contains file content.
  final String message;
}
