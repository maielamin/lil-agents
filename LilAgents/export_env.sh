# Load .env and export Claude auth variables for Xcode builds.
ENV_FILE="$SRCROOT/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$SRCROOT/../.env" ]; then
  ENV_FILE="$SRCROOT/../.env"
fi

if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    case "$line" in
      ""|\#*) continue ;;
    esac

    line="$(printf '%s' "$line" | sed -E 's/^export[[:space:]]+//')"
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"

    case "$value" in
      \"*\")
        value="${value#\"}"
        value="${value%\"}"
        ;;
      \'*\')
        value="${value#\'}"
        value="${value%\'}"
        ;;
    esac

    case "$key" in
      ANTHROPIC_API_KEY|CLAUDE_API_KEY)
        export "$key=$value"
        ;;
    esac
  done < "$ENV_FILE"

  if [ -n "${CLAUDE_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    export ANTHROPIC_API_KEY="$CLAUDE_API_KEY"
  fi

  if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_API_KEY:-}" ]; then
    export CLAUDE_API_KEY="$ANTHROPIC_API_KEY"
  fi
fi
