# Agent Code Structure

```
agent/
│
├── critic_agent_run_new.py              # PostgreSQL agent runner
├── critic_agent_run_new_sqlite.py       # SQLite agent runner
│
└── src/dbcommitagent/                   # Agent core source
    ├── __init__.py                       # Package entry, version, global config
    ├── __main__.py                       # python -m entry point
    ├── exceptions.py                     # Exception definitions
    │
    ├── agents/                           # Agent logic
    │   ├── __init__.py
    │   ├── default.py                    # Base agent class
    │   ├── interactive.py                # Interactive agent
    │   └── utils/
    │       ├── __init__.py
    │       └── prompt_user.py            # User prompt utility
    │
    ├── config/                           # Configuration
    │   ├── __init__.py
    │   └── pg_dbcommit_agent.yaml        # PostgreSQL agent config YAML
    │
    ├── environments/                     # Runtime environments
    │   ├── __init__.py
    │   ├── docker.py                     # Docker environment
    │   ├── local.py                      # Local environment
    │   ├── singularity.py                # Singularity environment
    │   └── extra/                        # Optional backends
    │       ├── __init__.py
    │       ├── bubblewrap.py
    │       └── contree.py
    │       
    │       
    │
    ├── models/                           # LLM model wrappers
    │   ├── __init__.py
    │   ├── litellm_model.py              # LiteLLM (default)
    │   ├── litellm_response_model.py
    │   ├── litellm_textbased_model.py
    │   ├── openrouter_model.py           # OpenRouter
    │   ├── openrouter_response_model.py
    │   ├── openrouter_textbased_model.py
    │   ├── portkey_model.py              # Portkey
    │   ├── portkey_response_model.py
    │   ├── requesty_model.py             # Requesty
    │   ├── test_models.py                # Model tests
    │   ├── extra/
    │   │   ├── __init__.py
    │   │   └── roulette.py
    │   └── utils/                        # Model utilities
    │       ├── __init__.py
    │       ├── actions_text.py           # Text action parsing
    │       ├── actions_toolcall.py       # Toolcall action parsing
    │       ├── actions_toolcall_response.py
    │       ├── anthropic_utils.py        # Anthropic helpers
    │       ├── cache_control.py          # Cache control
    │       ├── content_string.py
    │       ├── openai_multimodal.py
    │       └── retry.py                  # Retry mechanism
    │
    ├── run/                              # Run entry points
    │   ├── __init__.py
    │   ├── db_commit.py                  # Main runner
    │   ├── extra/__init__.py
    │   └── utilities/
    │       ├── __init__.py
    │       ├── config.py                 # Config loading
    │       ├── inspector.py              # Runtime inspector
    │       └── mini_extra.py
    │
    └── utils/                            # General utilities
        ├── __init__.py
        ├── log.py                        # Logging
        └── serialize.py                  # Serialization
```
