String environmentFileFor(String value) {
  switch (value.trim().toLowerCase()) {
    case 'local':
      return '.env.local';
    case 'production':
      return '.env';
    default:
      throw StateError(
        'ENV must be explicitly set to local or production; received "$value".',
      );
  }
}
