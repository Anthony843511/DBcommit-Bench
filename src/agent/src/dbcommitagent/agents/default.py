# 
# import json
# import logging
# import traceback
# from pathlib import Path
# 
# from jinja2 import StrictUndefined, Template
# from pydantic import BaseModel
# 
# from dbcommitagent import Environment, Model, __version__
# from dbcommitagent.exceptions import InterruptAgentFlow, LimitsExceeded
# from dbcommitagent.utils.serialize import recursive_merge
# 
# 
# class AgentConfig(BaseModel):
#     """Check the config files in dbcommitagent/config for example settings."""
# 
#     system_template: str
#     """Template for the system message (the first message)."""
#     instance_template: str
#     """Template for the first user message specifying the task (the second message overall)."""
#     step_limit: int = 0
#     """Maximum number of steps the agent can take."""
#     cost_limit: float = 3.0
#     """Stop agent after exceeding (!) this cost."""
#     output_path: Path | None = None
#     """Save the trajectory to this path."""
# 
# 
# class DefaultAgent:
#     def __init__(self, model: Model, env: Environment, *, config_class: type = AgentConfig, **kwargs):
#         """See the `AgentConfig` class for permitted keyword arguments."""
#         self.config = config_class(**kwargs)
#         self.messages: list[dict] = []
#         self.model = model
#         self.env = env
#         self.extra_template_vars = {}
#         self.logger = logging.getLogger("agent")
#         self.cost = 0.0
#         self.n_calls = 0
# 
#     def get_template_vars(self, **kwargs) -> dict:
#         return recursive_merge(
#             self.config.model_dump(),
#             self.env.get_template_vars(),
#             self.model.get_template_vars(),
#             {"n_model_calls": self.n_calls, "model_cost": self.cost},
#             self.extra_template_vars,
#             kwargs,
#         )
# 
#     def _render_template(self, template: str) -> str:
#         return Template(template, undefined=StrictUndefined).render(**self.get_template_vars())
# 
#     def add_messages(self, *messages: dict) -> list[dict]:
#         self.logger.debug(messages)  # set log level to debug to see
#         self.messages.extend(messages)
#         return list(messages)
# 
#     def handle_uncaught_exception(self, e: Exception) -> list[dict]:
#         return self.add_messages(
#             self.model.format_message(
#                 role="exit",
#                 content=str(e),
#                 extra={
#                     "exit_status": type(e).__name__,
#                     "submission": "",
#                     "exception_str": str(e),
#                     "traceback": traceback.format_exc(),
#                 },
#             )
#         )
# 
#     def run(self, task: str = "", **kwargs) -> dict:
#         """Run step() until agent is finished. Returns dictionary with exit_status, submission keys."""
#         self.extra_template_vars |= {"task": task, **kwargs}
#         self.messages = []
#         self.add_messages(
#             self.model.format_message(role="system", content=self._render_template(self.config.system_template)),
#             self.model.format_message(role="user", content=self._render_template(self.config.instance_template)),
#         )
#         while True:
#             try:
#                 self.step()
#             except InterruptAgentFlow as e:
#                 self.add_messages(*e.messages)
#             except Exception as e:
#                 self.handle_uncaught_exception(e)
#                 raise
#             finally:
#                 self.save(self.config.output_path)
#             if self.messages[-1].get("role") == "exit":
#                 break
#         return self.messages[-1].get("extra", {})
# 
#     def step(self) -> list[dict]:
#         """Query the LM, execute actions."""
#         return self.execute_actions(self.query())
# 
#     def query(self) -> dict:
#         """Query the model and return model messages. Override to add hooks."""
#         if 0 < self.config.step_limit <= self.n_calls or 0 < self.config.cost_limit <= self.cost:
#             raise LimitsExceeded(
#                 {
#                     "role": "exit",
#                     "content": "LimitsExceeded",
#                     "extra": {"exit_status": "LimitsExceeded", "submission": ""},
#                 }
#             )
#         self.n_calls += 1
#         message = self.model.query(self.messages)
#         self.cost += message.get("extra", {}).get("cost", 0.0)
#         self.add_messages(message)
#         return message
# 
#     def execute_actions(self, message: dict) -> list[dict]:
#         """Execute actions in message, add observation messages, return them."""
#         outputs = [self.env.execute(action) for action in message.get("extra", {}).get("actions", [])]
#         return self.add_messages(*self.model.format_observation_messages(message, outputs, self.get_template_vars()))
# 
#     def serialize(self, *extra_dicts) -> dict:
#         """Serialize agent state to a json-compatible nested dictionary for saving."""
#         last_message = self.messages[-1] if self.messages else {}
#         last_extra = last_message.get("extra", {})
#         agent_data = {
#             "info": {
#                 "model_stats": {
#                     "instance_cost": self.cost,
#                     "api_calls": self.n_calls,
#                 },
#                 "config": {
#                     "agent": self.config.model_dump(mode="json"),
#                     "agent_type": f"{self.__class__.__module__}.{self.__class__.__name__}",
#                 },
#                 "mini_version": __version__,
#                 "exit_status": last_extra.get("exit_status", ""),
#                 "submission": last_extra.get("submission", ""),
#             },
#             "messages": self.messages,
#             "trajectory_format": "dbcommit-agent-1.0",
#         }
#         return recursive_merge(agent_data, self.model.serialize(), self.env.serialize(), *extra_dicts)
# 
#     def save(self, path: Path | None, *extra_dicts) -> dict:
#         """Save the trajectory of the agent to a file if path is given. Returns full serialized data.
#         You can pass additional dictionaries with extra data to be (recursively) merged into the output data.
#         """
#         data = self.serialize(*extra_dicts)
#         if path:
#             path.parent.mkdir(parents=True, exist_ok=True)
#             path.write_text(json.dumps(data, indent=2))
#         return data
import json
import logging
import traceback
from pathlib import Path

from jinja2 import StrictUndefined, Template
from pydantic import BaseModel

from dbcommitagent import Environment, Model, __version__
from dbcommitagent.exceptions import InterruptAgentFlow, LimitsExceeded
from dbcommitagent.utils.serialize import recursive_merge


class AgentConfig(BaseModel):
    system_template: str
    instance_template: str
    step_limit: int = 0
    cost_limit: float = 3.0
    output_path: Path | None = None


class DefaultAgent:
    """
    Stable version:
    - supports tool execution
    - supports final SQL exit
    - fixes infinite tool loop
    - resolves tool/final conflict
    """

    def __init__(self, model: Model, env: Environment, *, config_class=AgentConfig, **kwargs):
        self.config = config_class(**kwargs)

        self.messages = []
        self.model = model
        self.env = env

        self.extra_template_vars = {}
        self.logger = logging.getLogger("agent")

        self.cost = 0.0
        self.n_calls = 0

        # =========================
        # 🔴 TERMINATION STATE
        # =========================
        self.terminated = False
        self.final_answer = None

    # =========================================================
    # Template rendering
    # =========================================================
    def get_template_vars(self, **kwargs):
        return recursive_merge(
            self.config.model_dump(),
            self.env.get_template_vars(),
            self.model.get_template_vars(),
            {
                "n_model_calls": self.n_calls,
                "model_cost": self.cost,
                "terminated": self.terminated,
            },
            self.extra_template_vars,
            kwargs,
        )

    def _render_template(self, template: str) -> str:
        return Template(template, undefined=StrictUndefined).render(
            **self.get_template_vars()
        )

    # =========================================================
    # Message handling
    # =========================================================
    def add_messages(self, *messages: dict):
        self.logger.debug(messages)
        self.messages.extend(messages)
        return list(messages)

    def handle_uncaught_exception(self, e: Exception):
        return self.add_messages(
            self.model.format_message(
                role="exit",
                content=str(e),
                extra={
                    "exit_status": type(e).__name__,
                    "submission": "",
                    "exception_str": str(e),
                    "traceback": traceback.format_exc(),
                },
            )
        )

    # =========================================================
    # RUN LOOP
    # =========================================================
    def run(self, task: str = "", **kwargs):
        self.extra_template_vars |= {"task": task, **kwargs}
        self.messages = []

        # init messages
        self.add_messages(
            self.model.format_message(
                role="system",
                content=self._render_template(self.config.system_template),
            ),
            self.model.format_message(
                role="user",
                content=self._render_template(self.config.instance_template),
            ),
        )

        while True:
            try:
                self.step()

            except InterruptAgentFlow as e:
                self.add_messages(*e.messages)

            except Exception as e:
                self.handle_uncaught_exception(e)
                raise

            finally:
                self.save(self.config.output_path)

            # =========================
            # termination condition
            # =========================
            if self.terminated:
                break

            if self.messages and self.messages[-1].get("role") == "exit":
                break

        return {
            "exit_status": "success",
            "submission": self.final_answer,
        }

    # =========================================================
    # STEP
    # =========================================================
    def step(self):
        message = self.query()

        # If already terminated, return directly
        if self.terminated:
            return []

        actions = message.get("extra", {}).get("actions", [])

        if not actions:
            # No actions but not final answer (should not reach here)
            self.logger.warning("Message has no actions but not detected as final answer")
            return []

        return self.execute_actions(message)

    # =========================================================
    # QUERY MODEL
    # =========================================================
    def query(self):
        # limits check
        if 0 < self.config.step_limit <= self.n_calls or 0 < self.config.cost_limit <= self.cost:
            raise LimitsExceeded(...)

        self.n_calls += 1
        message = self.model.query(self.messages)
        self.cost += message.get("extra", {}).get("cost", 0.0)

        # Detect final answer
        if self._is_final_answer(message):
            self._terminate(message)
            return message

        self.add_messages(message)
        return message

    # =========================================================
    # EXECUTION ENGINE
    # =========================================================
    def execute_actions(self, message: dict):
        actions = message.get("extra", {}).get("actions")

        # ✅ FINAL OUTPUT HANDLING
        if not actions:
            return self.add_messages(
                self.model.format_message(
                    role="exit",
                    content=message.get("content", ""),
                    extra={
                        "exit_status": "Submitted",
                        "submission": message.get("content", "")
                    }
                )
            )

        outputs = [self.env.execute(a) for a in actions]
        return self.add_messages(
            *self.model.format_observation_messages(
                message, outputs, self.get_template_vars()
            )
        )
    # =========================================================
    # TERMINATION LOGIC
    # =========================================================
    def _is_final_answer(self, message: dict) -> bool:
        """Check if it is a final answer"""
        content = message.get("content", "")
        actions = message.get("extra", {}).get("actions", [])

        if len(actions) > 0:
            return False
        if "cat <<" in content:
            return True
        # Detect various final answer formats
        final_patterns = [
            "```sql",
            "```xml",
            "<test_cases>",
            "<analysis>",
        ]

        return any(pattern in content for pattern in final_patterns)

    def _terminate(self, message: dict):
        self.terminated = True
        self.final_answer = message.get("content")

        self.add_messages(
            self.model.format_message(
                role="exit",
                content=self.final_answer,
                extra={
                    "exit_status": "success",
                    "submission": self.final_answer,
                },
            )
        )

    def _terminate_from_action(self, action: dict):
        self.terminated = True
        self.final_answer = action.get("content")

        self.add_messages(
            self.model.format_message(
                role="exit",
                content=self.final_answer,
                extra={
                    "exit_status": "success",
                    "submission": self.final_answer,
                },
            )
        )

    # =========================================================
    # SERIALIZATION
    # =========================================================
    def serialize(self, *extra_dicts):
        last_message = self.messages[-1] if self.messages else {}
        last_extra = last_message.get("extra", {})

        agent_data = {
            "info": {
                "model_stats": {
                    "instance_cost": self.cost,
                    "api_calls": self.n_calls,
                },
                "config": {
                    "agent": self.config.model_dump(mode="json"),
                    "agent_type": f"{self.__class__.__module__}.{self.__class__.__name__}",
                },
                "mini_version": __version__,
                "exit_status": last_extra.get("exit_status", ""),
                "submission": self.final_answer,
            },
            "messages": self.messages,
            "trajectory_format": "dbcommit-agent",
        }

        return recursive_merge(
            agent_data,
            self.model.serialize(),
            self.env.serialize(),
            *extra_dicts,
        )

    # =========================================================
    # SAVE
    # =========================================================
    def save(self, path: Path | None, *extra_dicts):
        data = self.serialize(*extra_dicts)

        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data, indent=2))

        return data