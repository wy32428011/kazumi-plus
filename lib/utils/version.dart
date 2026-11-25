import 'dart:math';

class _ParsedVersion {
  const _ParsedVersion(this.core, this.preRelease);

  final List<int> core;
  final List<String> preRelease;
}

_ParsedVersion? _parseVersion(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  final plusIndex = value.indexOf('+');
  if (plusIndex != -1) {
    value = value.substring(0, plusIndex);
  }
  if (value.isEmpty) return null;

  String corePart = value;
  List<String> preRelease = const [];
  final dashIndex = value.indexOf('-');
  if (dashIndex != -1) {
    corePart = value.substring(0, dashIndex);
    final prePart = value.substring(dashIndex + 1);
    if (prePart.isEmpty) return null;
    preRelease = prePart.split('.');
    if (preRelease.any((segment) => segment.isEmpty)) return null;
  }

  final coreSegments = corePart.split('.');
  if (coreSegments.isEmpty) return null;
  final coreNumbers = <int>[];
  for (final segment in coreSegments) {
    final parsed = int.tryParse(segment);
    if (parsed == null || parsed < 0) return null;
    coreNumbers.add(parsed);
  }
  return _ParsedVersion(coreNumbers, preRelease);
}

int _comparePreRelease(List<String> local, List<String> remote) {
  if (local.isEmpty && remote.isEmpty) return 0;
  if (local.isEmpty) return 1;
  if (remote.isEmpty) return -1;

  final minLength = min(local.length, remote.length);
  for (var i = 0; i < minLength; i++) {
    if (local[i] == remote[i]) continue;
    final localNum = int.tryParse(local[i]);
    final remoteNum = int.tryParse(remote[i]);
    if (localNum != null && remoteNum != null) {
      return localNum.compareTo(remoteNum);
    }
    if (localNum != null) return -1;
    if (remoteNum != null) return 1;
    return local[i].compareTo(remote[i]);
  }
  return local.length.compareTo(remote.length);
}

bool needUpdate(String localVersion, String remoteVersion) {
  final local = _parseVersion(localVersion);
  final remote = _parseVersion(remoteVersion);
  if (local == null || remote == null) return false;

  final maxLength = max(local.core.length, remote.core.length);
  for (var i = 0; i < maxLength; i++) {
    final localSegment = i < local.core.length ? local.core[i] : 0;
    final remoteSegment = i < remote.core.length ? remote.core[i] : 0;
    if (remoteSegment > localSegment) {
      return true;
    } else if (remoteSegment < localSegment) {
      return false;
    }
  }
  return _comparePreRelease(local.preRelease, remote.preRelease) < 0;
}
