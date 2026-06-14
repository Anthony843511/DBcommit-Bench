#!/usr/bin/env python3

"""Run dbcommitagent in your local environment. This is the default executable `mini`."""

import os
import sys
from pathlib import Path
from typing import Any

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../")))
import typer
from rich.console import Console

from dbcommitagent import global_config_dir
from dbcommitagent.agents import get_agent
from dbcommitagent.agents.utils.prompt_user import _multiline_prompt
from dbcommitagent.config import builtin_config_dir, get_config_from_spec
from dbcommitagent.environments import get_environment
from dbcommitagent.models import get_model
from dbcommitagent.run.utilities.config import configure_if_first_time
from dbcommitagent.utils.serialize import UNSET, recursive_merge

DEFAULT_CONFIG_FILE = Path(".../src/dbcommitagent/config/pg_dbcommit_agent.yaml")
DEFAULT_OUTPUT_FILE = global_config_dir / "last_agent_run.traj.json"



_HELP_TEXT = """Run dbcommitagentin your local environment.

"""

_CONFIG_SPEC_HELP_TEXT = """Path to config files, filenames, or key-value pairs.

[bold red]IMPORTANT:[/bold red] [red]If you set this option, the default config file will not be used.[/red]
So you need to explicitly set it e.g., with [bold green]-c mini.yaml <other options>[/bold green]

Multiple configs will be recursively merged.

"""

console = Console(highlight=False)
app = typer.Typer(rich_markup_mode="rich")


# fmt: off
@app.command(help=_HELP_TEXT)
def main(
    model_name: str | None = typer.Option(None, "-m", "--model", help="Model to use",),
    model_class: str | None = typer.Option(None, "--model-class", help="Model class to use (e.g., 'litellm' or 'dbcommitagent.models.litellm_model.LitellmModel')", rich_help_panel="Advanced"),
    agent_class: str | None = typer.Option(None, "--agent-class", help="Agent class to use (e.g., 'interactive' or 'dbcommitagent.agents.interactive.InteractiveAgent')", rich_help_panel="Advanced"),
    environment_class: str | None = typer.Option(None, "--environment-class", help="Environment class to use (e.g., 'local' or 'dbcommitagent.environments.local.LocalEnvironment')", rich_help_panel="Advanced"),
    task: str | None = typer.Option(None, "-t", "--task", help="修改的文件路径", show_default=False),
    problem: str | None = typer.Option(None, "-p", "--problem", help="具体的问题描述"), # 新增问题描述
    task_id: int | None = typer.Option(None, "-i", "--task-id", help="具体的问题id"), # 新增问题id
    yolo: bool = typer.Option(False, "-y", "--yolo", help="Run without confirmation"),
    cost_limit: float | None = typer.Option(None, "-l", "--cost-limit", help="Cost limit. Set to 0 to disable."),
    config_spec: list[str] = typer.Option([str(DEFAULT_CONFIG_FILE)], "-c", "--config", help=_CONFIG_SPEC_HELP_TEXT),
    output: Path | None = typer.Option(DEFAULT_OUTPUT_FILE, "-o", "--output", help="Output trajectory file"),
    exit_immediately: bool = typer.Option(False, "--exit-immediately", help="Exit immediately when the agent wants to finish instead of prompting.", rich_help_panel="Advanced"),
) -> Any:
    # fmt: on
    configure_if_first_time()

    # Build the config from the command line arguments
    console.print(f"Building agent config from specs: [bold green]{config_spec}[/bold green]")
    configs = [get_config_from_spec(spec) for spec in config_spec]
    configs.append({
        "run": {
            "task": task or UNSET,
        },
        "agent": {
            "agent_class": agent_class or UNSET,
            "mode": "yolo" if yolo else UNSET,
            "cost_limit": cost_limit or UNSET,
            "confirm_exit": False if exit_immediately else UNSET,
            "output_path": output or UNSET,
        },
        "model": {
            "model_class": model_class or UNSET,
            "model_name": model_name or UNSET,
        },
        "environment": {
            "environment_class": environment_class or UNSET,
        },
    })
    config = recursive_merge(*configs)
    # === ⚙️ 新增代码开始：注入 Database Path (优化版) ===
    try:
        # 1. 确定任务 ID (用于找源码路径)
        # 优先使用 -t 传入的 ID，如果没有，则尝试从 config 读取
        task_file = task if task else config.get("run", {}).get("id")

        if not task_file:
            console.print("[bold red]❌ 必须通过 -t 指定任务 ID (例如 california_schools)[/bold red]")
            raise typer.Exit(code=1)

        # 2. 确定问题描述 (用于问 Agent)
        # 优先使用 -p 传入的问题，如果没有，则使用交互式输入
        run_task = problem
        if not run_task:
            console.print("[bold yellow]⚠️ 未提供问题描述，进入交互模式...[/bold yellow]")
            # 这里可以保留你原来的交互式输入逻辑
            run_task = _multiline_prompt()

            # 3. 拼接数据库路径 (使用 task_id)
        db_root_dir = config.get("agent", {}).get("db_root_dir", "./database")
        #  具体的源码路径
        # db_filename = f"{task_id}_template.sqlite"
        full_db_path = os.path.join(db_root_dir, task_file)
        print("full_db_path:",full_db_path)
        # 4. 注入变量
        if "agent" not in config:
            config["agent"] = {}
        config["agent"]["db_path"] = full_db_path
        config["agent"]["task_id"] = task_id  # 也可以注入 task_id 供模板使用

        console.print(f"[bold green]✅ 数据库路径已注入!: {full_db_path}[/bold green]")
        console.print(f"[bold blue]🚀 准备执行任务: {run_task}[/bold blue]")
        console.print(f"[bold blue]🚀 任务ID: {task_id}[/bold blue]")


    except Exception as e:
        console.print(f"[bold red]❌ Error while processing database path: {e}[/bold red]")
        raise
    # === ✅ 新增代码结束 ===
    # if (run_task := config.get("run", {}).get("task", UNSET)) is UNSET:
    #     console.print("[bold yellow]What do you want to do?")
    #     run_task = _multiline_prompt()
    #     console.print("[bold green]Got that, thanks![/bold green]")
    #
    # model = get_model(config=config.get("model", {}))
    # env = get_environment(config.get("environment", {}), default_type="local")
    # agent = get_agent(model, env, config.get("agent", {}), default_type="interactive")
    # # 直接更新 agent 的 extra_template_vars
    # agent.extra_template_vars["db_path"] = full_db_path
    # # 更改结束
    # agent.run(run_task)
    # if (output_path := config.get("agent", {}).get("output_path")):
    #     console.print(f"Saved trajectory to [bold green]'{output_path}'[/bold green]")
    # --- ✅ USE THE run_task VARIABLE WE ALREADY DEFINED ABOVE ---
    model = get_model(config=config.get("model", {}))

    env = get_environment(config.get("environment", {}), default_type="local")
    agent = get_agent(model, env, config.get("agent", {}), default_type="interactive")
    # 新增，强制刷新模板上下文
    if not hasattr(agent, 'extra_template_vars'):
        agent.extra_template_vars = {}
    # 直接更新 agent 的 extra_template_vars
    agent.extra_template_vars["db_path"] = full_db_path
    agent.extra_template_vars["task_id"] = task_id
    agent.extra_template_vars["db_root_dir"] = config.get("agent", {}).get("db_root_dir",
                                                                           "/home/shihao/postgresql-13.23-copy")
    # 运行 Agent (使用上面定义的 run_task)
    agent.run(run_task)

    if output_path := config.get("agent", {}).get("output_path"):
        console.print(f"Saved trajectory to [bold green]'{output_path}'[/bold green]")
    return agent


if __name__ == "__main__":
    app()
