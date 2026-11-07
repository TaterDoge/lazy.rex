return {
  "taterdoge/smart-title-rex",
  -- For local development, set dir = "/absolute/path/to/smart-title-rex".
  main = "smart-title-rex",
  opts = {
    url = "http://localhost:3425/v1/chat/completions",
    api_key = os.getenv("OPENAI_API_KEY") or "",
    model = "inceptionlabs/mercury-3",
    reasoning_effort = "none",
    poll_interval = 10,
    language = "Chinese",
  },
}
