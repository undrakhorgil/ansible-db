# Vendored from ansible.posix.profile_tasks; TASKS RECAP omits Ansible's "role_name : " task prefix.

from __future__ import annotations

DOCUMENTATION = """
    name: profile_tasks_strip
    type: aggregate
    short_description: like profile_tasks, without role prefix in task names
    description:
      - Same timing/recap behavior as C(ansible.posix.profile_tasks); recap lines use the task C(name) only.
    extends_documentation_fragment:
      - default_callback
    options:
      output_limit:
        description: Number of tasks to display in the summary
        default: 20
        ini:
          - section: callback_profile_tasks_strip
            key: task_output_limit
      sort_order:
        description: Sort order for summary tasks
        choices: ['descending', 'ascending', 'none']
        default: 'descending'
        ini:
          - section: callback_profile_tasks_strip
            key: sort_order
      summary_only:
        description: Only show summary, not per-task timing lines
        type: bool
        default: false
        ini:
          - section: callback_profile_tasks_strip
            key: summary_only
      datetime_format:
        description: strftime format for timestamps
        default: '%A %d %B %Y %H:%M:%S %z'
        ini:
          - section: callback_profile_tasks_strip
            key: datetime_format
"""

import collections
from datetime import datetime

from ansible.module_utils.six.moves import reduce
from ansible.plugins.callback import CallbackBase


dt0 = dtn = datetime.now().astimezone()


def secondsToStr(t):
    def rediv(ll, b):
        return list(divmod(ll[0], b)) + ll[1:]

    return "%d:%02d:%02d.%03d" % tuple(reduce(rediv, [[t * 1000], 1000, 60, 60]))


def filled(msg, fchar="*"):
    if len(msg) == 0:
        width = 79
    else:
        msg = "%s " % msg
        width = 79 - len(msg)
    if width < 3:
        width = 3
    filler = fchar * width
    return "%s%s " % (msg, filler)


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


def timestamp(self):
    if self.current is not None:
        elapsed = (datetime.now().astimezone() - self.stats[self.current]["started"]).total_seconds()
        self.stats[self.current]["elapsed"] += elapsed


def tasktime(self):
    global dtn
    cdtn = datetime.now().astimezone()
    datetime_current = cdtn.strftime(self.datetime_format)
    time_elapsed = secondsToStr((cdtn - dtn).total_seconds())
    time_total_elapsed = secondsToStr((cdtn - dt0).total_seconds())
    dtn = cdtn
    return filled("%s (%s)%s%s" % (datetime_current, time_elapsed, " " * 7, time_total_elapsed))


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "profile_tasks_strip"
    CALLBACK_NEEDS_WHITELIST = True

    def __init__(self):
        self.stats = collections.OrderedDict()
        self.current = None
        self.sort_order = None
        self.summary_only = None
        self.task_output_limit = None
        self.datetime_format = None
        super(CallbackModule, self).__init__()

    def set_options(self, task_keys=None, var_options=None, direct=None):
        super(CallbackModule, self).set_options(task_keys=task_keys, var_options=var_options, direct=direct)
        self.sort_order = self.get_option("sort_order")
        if self.sort_order is not None:
            if self.sort_order == "ascending":
                self.sort_order = False
            elif self.sort_order == "descending":
                self.sort_order = True
            elif self.sort_order == "none":
                self.sort_order = None
        self.summary_only = self.get_option("summary_only")
        self.task_output_limit = self.get_option("output_limit")
        if self.task_output_limit is not None:
            if self.task_output_limit == "all":
                self.task_output_limit = None
            else:
                self.task_output_limit = int(self.task_output_limit)
        self.datetime_format = self.get_option("datetime_format")
        if self.datetime_format is not None:
            if self.datetime_format == "iso8601":
                self.datetime_format = "%Y-%m-%dT%H:%M:%S.%f"

    def _display_tasktime(self):
        if not self.summary_only:
            self._display.display(tasktime(self))

    def _record_task(self, task):
        self._display_tasktime()
        timestamp(self)
        self.current = task._uuid
        dtn_local = datetime.now().astimezone()
        display_name = _task_display_name(task)
        if self.current not in self.stats:
            self.stats[self.current] = {"started": dtn_local, "elapsed": 0.0, "name": display_name}
        else:
            self.stats[self.current]["started"] = dtn_local
        if self._display.verbosity >= 2:
            self.stats[self.current]["path"] = task.get_path()

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._record_task(task)

    def v2_playbook_on_handler_task_start(self, task):
        self._record_task(task)

    def v2_playbook_on_stats(self, stats):
        self._display.banner("TASKS RECAP")
        self._display.display(tasktime(self))
        self._display.display(filled("", fchar="="))
        timestamp(self)
        self.current = None
        results = list(self.stats.items())
        if self.sort_order is not None:
            results = sorted(self.stats.items(), key=lambda x: x[1]["elapsed"], reverse=self.sort_order)
        results = list(results)[: self.task_output_limit]
        for _uuid, result in results:
            msg = "{0:-<{2}}{1:->9}".format(
                result["name"] + " ",
                " {0:.02f}s".format(result["elapsed"]),
                self._display.columns - 9,
            )
            if "path" in result:
                msg += "\n{0:-<{1}}".format(result["path"] + " ", self._display.columns)
            self._display.display(msg)
