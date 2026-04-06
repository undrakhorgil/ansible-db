"""
Custom stdout callback to remove the long '*************' banners.

Keeps the default callback behavior for results, but prints a plain:
  TASK [name]
line instead of the banner.

Role tasks omit the Ansible "role_name : " prefix so output matches the task's
declared name (same as profile_tasks_strip recap).
"""

from __future__ import annotations

DOCUMENTATION = r"""
    name: clean
    type: stdout
    short_description: default-like output with simple TASK lines instead of star banners
    extends_documentation_fragment:
      - ansible.builtin.default_callback
"""

from ansible.plugins.callback.default import CallbackModule as DefaultCallback


def _task_display_name(task) -> str:
    raw = task.get_name().strip()
    role = getattr(task, "_role", None)
    if role is None:
        return raw
    rname = role.get_name()
    prefix = f"{rname} : "
    if raw.startswith(prefix):
        return raw[len(prefix):].strip()
    return raw


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "clean"

    def v2_playbook_on_task_start(self, task, is_conditional):  # noqa: N802 (Ansible naming)
        # Default callback prints a banner with lots of '*'. Replace with a simple line.
        name = _task_display_name(task)
        self._display.display(f"TASK [{name}]")
