"""Generate the JavaScript Cloudflare Worker task bundle.

This project keeps the task logic in Python as the source of truth.  The
Cloudflare production Worker is plain JavaScript, so this script translates the
small Python subset used by ``src/tasks`` into ESM modules.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path
from typing import Iterable

import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS_DIR = ROOT / "src" / "tasks"
WORKER_SRC = ROOT / "cloudflare_worker" / "src"
WORKER_TASKS_DIR = WORKER_SRC / "tasks"

RUNTIME_IMPORTS = [
    "DateTime",
    "Registry",
    "TaskModule",
    "contains",
    "pyAdd",
    "pyAny",
    "pyCount",
    "pyDict",
    "pyDivmod",
    "pyEnumerate",
    "pyGet",
    "pyInt",
    "pyIsSubset",
    "pyItems",
    "pyLen",
    "pyMax",
    "pyMin",
    "pyRange",
    "pySet",
    "pySlice",
    "pySorted",
    "pyStr",
    "pyTruthy",
    "randomChoice",
    "randomSample",
    "sleep",
]

COMMON_IMPORTS = [
    "c_get_material_quantity",
    "c_get_doushenta_cd",
    "c_邪神秘宝",
    "c_帮派商会",
    "c_任务派遣中心",
    "c_侠士客栈",
    "c_帮派巡礼",
    "c_深渊秘境",
    "c_龙凰论武",
    "c_幸运金蛋",
    "c_客栈同福",
    "c_大笨钟",
    "c_领取今日活跃度奖励",
]


class TranslationError(Exception):
    pass


def js_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def indent(text: str, level: int = 1) -> str:
    prefix = "  " * level
    return "\n".join(prefix + line if line else line for line in text.splitlines())


def function_has_yield(node: ast.AST) -> bool:
    return any(isinstance(child, (ast.Yield, ast.YieldFrom)) for child in ast.walk(node))


def decorator_task_name(node: ast.AsyncFunctionDef) -> str | None:
    for decorator in node.decorator_list:
        if not isinstance(decorator, ast.Call):
            continue
        if not isinstance(decorator.func, ast.Name) or decorator.func.id != "register":
            continue
        if decorator.args:
            arg = decorator.args[0]
            if not isinstance(arg, ast.Constant) or not isinstance(arg.value, str):
                raise TranslationError(f"unsupported register arg at line {node.lineno}")
            return arg.value
        return node.name
    return None


class JsWriter:
    def __init__(self, module_name: str):
        self.module_name = module_name
        self.class_stack: list[str] = []
        self.class_names: set[str] = set()

    def translate_module(self, tree: ast.Module) -> tuple[str, list[str]]:
        lines: list[str] = []
        registered: list[str] = []
        self.class_names = {node.name for node in tree.body if isinstance(node, ast.ClassDef)}

        for node in tree.body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            if self._is_registry_setup(node):
                continue
            if isinstance(node, ast.AsyncFunctionDef):
                lines.append(self.function_def(node, is_async=True))
                task_name = decorator_task_name(node)
                if task_name is not None:
                    registered.append(task_name)
                    lines.append(f"register({js_string(task_name)}, {node.name});")
                continue
            if isinstance(node, ast.FunctionDef):
                lines.append(self.function_def(node, is_async=False))
                continue
            if isinstance(node, ast.ClassDef):
                lines.append(self.class_def(node))
                continue
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                continue
            lines.extend(self.stmt(node))

        return "\n\n".join(lines).rstrip() + "\n", registered

    def _is_registry_setup(self, node: ast.AST) -> bool:
        if not isinstance(node, ast.Assign):
            return False
        names = [target.id for target in node.targets if isinstance(target, ast.Name)]
        return any(name in {"registry", "register"} for name in names)

    def class_def(self, node: ast.ClassDef) -> str:
        self.class_stack.append(node.name)
        body: list[str] = []
        for item in node.body:
            if isinstance(item, ast.Expr) and isinstance(item.value, ast.Constant):
                continue
            if isinstance(item, ast.AsyncFunctionDef):
                body.append(self.method_def(item, is_async=True))
            elif isinstance(item, ast.FunctionDef):
                body.append(self.method_def(item, is_async=False))
            else:
                body.extend(self.stmt(item))
        self.class_stack.pop()
        return f"class {node.name} {{\n{indent(chr(10).join(body))}\n}}"

    def method_def(self, node: ast.FunctionDef | ast.AsyncFunctionDef, is_async: bool) -> str:
        name = "constructor" if node.name == "__init__" else node.name
        args = [arg.arg for arg in node.args.args]
        if args and args[0] == "self":
            args = args[1:]
        header = f"{'async ' if is_async else ''}{name}({', '.join(args)})"
        body = self.block(node.body, function_node=node, arg_names=set(args) | {"self"})
        return f"{header} {{\n{indent(body)}\n}}"

    def function_def(self, node: ast.FunctionDef | ast.AsyncFunctionDef, is_async: bool) -> str:
        generator = function_has_yield(node)
        args = [arg.arg for arg in node.args.args]
        prefix = "async function " if is_async else ("function* " if generator else "function ")
        body = self.block(node.body, function_node=node, arg_names=set(args))
        return f"{prefix}{node.name}({', '.join(args)}) {{\n{indent(body)}\n}}"

    def collect_assigned_names(
        self,
        node: ast.FunctionDef | ast.AsyncFunctionDef,
        arg_names: set[str],
    ) -> list[str]:
        names: set[str] = set()

        def add_target(target: ast.AST) -> None:
            if isinstance(target, ast.Name):
                if target.id not in arg_names:
                    names.add(target.id)
            elif isinstance(target, (ast.Tuple, ast.List)):
                for element in target.elts:
                    add_target(element)

        for child in ast.walk(node):
            if isinstance(child, ast.Assign):
                for target in child.targets:
                    add_target(target)
            elif isinstance(child, ast.AnnAssign):
                add_target(child.target)
            elif isinstance(child, ast.AugAssign):
                add_target(child.target)
            elif isinstance(child, ast.For):
                add_target(child.target)
            elif isinstance(child, ast.NamedExpr):
                add_target(child.target)
        return sorted(name for name in names if name != "_")

    def block(
        self,
        body: list[ast.stmt],
        function_node: ast.FunctionDef | ast.AsyncFunctionDef | None = None,
        arg_names: set[str] | None = None,
    ) -> str:
        lines: list[str] = []
        if function_node is not None:
            assigned = self.collect_assigned_names(function_node, arg_names or set())
            if assigned:
                lines.append(f"var {', '.join(assigned)};")
        for stmt in body:
            if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
                continue
            lines.extend(self.stmt(stmt))
        return "\n".join(lines) if lines else "// pass"

    def stmt(self, node: ast.stmt) -> list[str]:
        if isinstance(node, ast.Assign):
            value = self.expr(node.value)
            lines = []
            for target in node.targets:
                lines.append(f"{self.assign_target(target)} = {value};")
            return lines
        if isinstance(node, ast.AnnAssign):
            if node.value is None:
                return []
            return [f"{self.assign_target(node.target)} = {self.expr(node.value)};"]
        if isinstance(node, ast.AugAssign):
            target = self.assign_target(node.target)
            value = self.expr(node.value)
            if isinstance(node.op, ast.Add):
                return [f"{target} = pyAdd({target}, {value});"]
            if isinstance(node.op, ast.Sub):
                return [f"{target} -= {value};"]
            raise TranslationError(f"unsupported augassign {type(node.op).__name__} line {node.lineno}")
        if isinstance(node, ast.Expr):
            return [f"{self.expr(node.value)};"]
        if isinstance(node, ast.Return):
            if node.value is None:
                return ["return;"]
            return [f"return {self.expr(node.value)};"]
        if isinstance(node, ast.Break):
            return ["break;"]
        if isinstance(node, ast.Continue):
            return ["continue;"]
        if isinstance(node, ast.If):
            return [self.if_stmt(node)]
        if isinstance(node, ast.For):
            return [self.for_stmt(node)]
        if isinstance(node, ast.While):
            return [self.while_stmt(node)]
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return [self.function_def(node, is_async=isinstance(node, ast.AsyncFunctionDef))]
        if isinstance(node, ast.Pass):
            return ["// pass"]
        raise TranslationError(f"unsupported statement {type(node).__name__} line {getattr(node, 'lineno', '?')}")

    def if_stmt(self, node: ast.If) -> str:
        condition = self.truthy_expr(node.test)
        body = indent(self.block(node.body))
        if not node.orelse:
            return f"if ({condition}) {{\n{body}\n}}"

        if len(node.orelse) == 1 and isinstance(node.orelse[0], ast.If):
            else_block = self.if_stmt(node.orelse[0])
            return f"if ({condition}) {{\n{body}\n}} else {else_block}"

        orelse = indent(self.block(node.orelse))
        return f"if ({condition}) {{\n{body}\n}} else {{\n{orelse}\n}}"

    def for_stmt(self, node: ast.For) -> str:
        target = self.for_target(node.target)
        iterable = self.iterable_expr(node.iter)
        body = indent(self.block(node.body))
        if node.orelse:
            raise TranslationError(f"for/else is not supported line {node.lineno}")
        return f"for (let {target} of {iterable}) {{\n{body}\n}}"

    def while_stmt(self, node: ast.While) -> str:
        if node.orelse:
            raise TranslationError(f"while/else is not supported line {node.lineno}")
        body = indent(self.block(node.body))
        return f"while ({self.truthy_expr(node.test)}) {{\n{body}\n}}"

    def for_target(self, target: ast.AST) -> str:
        if isinstance(target, ast.Name):
            return target.id
        if isinstance(target, (ast.Tuple, ast.List)):
            return "[" + ", ".join(self.for_target(element) for element in target.elts) + "]"
        raise TranslationError(f"unsupported for target {type(target).__name__}")

    def assign_target(self, target: ast.AST) -> str:
        if isinstance(target, ast.Name):
            return target.id
        if isinstance(target, ast.Attribute):
            return self.expr(target)
        if isinstance(target, ast.Subscript):
            return self.expr(target)
        if isinstance(target, (ast.Tuple, ast.List)):
            return "[" + ", ".join(self.assign_target(element) for element in target.elts) + "]"
        raise TranslationError(f"unsupported assignment target {type(target).__name__}")

    def iterable_expr(self, node: ast.AST) -> str:
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "items":
            return f"pyItems({self.expr(node.func.value)})"
        return self.expr(node)

    def truthy_expr(self, node: ast.AST) -> str:
        if isinstance(node, ast.BoolOp):
            return self.expr(node, truthy_bool=True)
        if isinstance(node, (ast.Compare, ast.UnaryOp)):
            return self.expr(node)
        return f"pyTruthy({self.expr(node)})"

    def expr(self, node: ast.AST, truthy_bool: bool = False) -> str:
        if isinstance(node, ast.Constant):
            if node.value is None:
                return "null"
            if node.value is True:
                return "true"
            if node.value is False:
                return "false"
            if isinstance(node.value, str):
                return js_string(node.value)
            return repr(node.value)
        if isinstance(node, ast.Name):
            if node.id == "None":
                return "null"
            if node.id == "True":
                return "true"
            if node.id == "False":
                return "false"
            if node.id == "self":
                return "this"
            return node.id
        if isinstance(node, ast.Attribute):
            value = self.expr(node.value)
            if value == "this":
                return f"this.{node.attr}"
            return f"{value}.{node.attr}"
        if isinstance(node, ast.List):
            return "[" + ", ".join(self.expr(element) for element in node.elts) + "]"
        if isinstance(node, ast.Tuple):
            return "[" + ", ".join(self.expr(element) for element in node.elts) + "]"
        if isinstance(node, ast.Set):
            return "pySet([" + ", ".join(self.expr(element) for element in node.elts) + "])"
        if isinstance(node, ast.Dict):
            parts = []
            for key, value in zip(node.keys, node.values):
                if key is None:
                    raise TranslationError("dict unpack is not supported")
                parts.append(f"[{self.expr(key)}]: {self.expr(value)}")
            return "({" + ", ".join(parts) + "})"
        if isinstance(node, ast.JoinedStr):
            return self.joined_str(node)
        if isinstance(node, ast.BinOp):
            return self.binop(node)
        if isinstance(node, ast.UnaryOp):
            if isinstance(node.op, ast.Not):
                return f"!pyTruthy({self.expr(node.operand)})"
            if isinstance(node.op, ast.USub):
                return f"(-{self.expr(node.operand)})"
            raise TranslationError(f"unsupported unary op {type(node.op).__name__}")
        if isinstance(node, ast.BoolOp):
            op = " && " if isinstance(node.op, ast.And) else " || "
            values = [self.truthy_expr(value) for value in node.values]
            return "(" + op.join(values) + ")"
        if isinstance(node, ast.Compare):
            return self.compare(node)
        if isinstance(node, ast.Call):
            return self.call(node)
        if isinstance(node, ast.Await):
            return f"await {self.expr(node.value)}"
        if isinstance(node, ast.Subscript):
            return self.subscript(node)
        if isinstance(node, ast.Slice):
            raise TranslationError("slice should be handled by subscript")
        if isinstance(node, ast.NamedExpr):
            return f"({self.assign_target(node.target)} = {self.expr(node.value)})"
        if isinstance(node, ast.Lambda):
            args = [arg.arg for arg in node.args.args]
            return f"({', '.join(args)}) => {self.expr(node.body)}"
        if isinstance(node, ast.Yield):
            return "yield" if node.value is None else f"yield {self.expr(node.value)}"
        if isinstance(node, ast.GeneratorExp):
            return self.generator_expr(node)
        raise TranslationError(f"unsupported expression {type(node).__name__} line {getattr(node, 'lineno', '?')}")

    def joined_str(self, node: ast.JoinedStr) -> str:
        parts: list[str] = ["`"]
        for value in node.values:
            if isinstance(value, ast.Constant):
                text = str(value.value)
                parts.append(text.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${"))
            elif isinstance(value, ast.FormattedValue):
                parts.append("${" + self.expr(value.value) + "}")
            else:
                raise TranslationError("unsupported f-string value")
        parts.append("`")
        return "".join(parts)

    def binop(self, node: ast.BinOp) -> str:
        left = self.expr(node.left)
        right = self.expr(node.right)
        if isinstance(node.op, ast.Add):
            return f"pyAdd({left}, {right})"
        if isinstance(node.op, ast.Sub):
            return f"({left} - {right})"
        if isinstance(node.op, ast.FloorDiv):
            return f"Math.floor({left} / {right})"
        if isinstance(node.op, ast.BitOr):
            return f"({left} | {right})"
        raise TranslationError(f"unsupported binary op {type(node.op).__name__} line {node.lineno}")

    def compare(self, node: ast.Compare) -> str:
        parts: list[str] = []
        left = self.expr(node.left)
        for op, comparator in zip(node.ops, node.comparators):
            right = self.expr(comparator)
            if isinstance(op, ast.In):
                parts.append(f"contains({right}, {left})")
            elif isinstance(op, ast.NotIn):
                parts.append(f"!contains({right}, {left})")
            elif isinstance(op, ast.Is):
                parts.append(f"{left} === {right}")
            elif isinstance(op, ast.IsNot):
                parts.append(f"{left} !== {right}")
            elif isinstance(op, ast.Eq):
                parts.append(f"{left} === {right}")
            elif isinstance(op, ast.NotEq):
                parts.append(f"{left} !== {right}")
            elif isinstance(op, ast.Lt):
                parts.append(f"{left} < {right}")
            elif isinstance(op, ast.LtE):
                parts.append(f"{left} <= {right}")
            elif isinstance(op, ast.Gt):
                parts.append(f"{left} > {right}")
            elif isinstance(op, ast.GtE):
                parts.append(f"{left} >= {right}")
            else:
                raise TranslationError(f"unsupported comparison op {type(op).__name__}")
            left = right
        return "(" + " && ".join(parts) + ")"

    def subscript(self, node: ast.Subscript) -> str:
        if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == "globals":
            base = "__globals"
        else:
            base = self.expr(node.value)
        if isinstance(node.slice, ast.Slice):
            lower = "null" if node.slice.lower is None else self.expr(node.slice.lower)
            upper = "null" if node.slice.upper is None else self.expr(node.slice.upper)
            if node.slice.step is not None:
                raise TranslationError("slice step is not supported")
            return f"pySlice({base}, {lower}, {upper})"
        return f"{base}[{self.expr(node.slice)}]"

    def call(self, node: ast.Call) -> str:
        if isinstance(node.func, ast.Name):
            name = node.func.id
            if name in self.class_names:
                return f"new {name}({', '.join(self.expr(arg) for arg in node.args)})"
            if name == "range":
                return f"pyRange({', '.join(self.expr(arg) for arg in node.args)})"
            if name == "enumerate":
                return f"pyEnumerate({', '.join(self.expr(arg) for arg in node.args)})"
            if name == "int":
                return f"pyInt({self.expr(node.args[0])})"
            if name == "str":
                return f"pyStr({self.expr(node.args[0])})"
            if name == "len":
                return f"pyLen({self.expr(node.args[0])})"
            if name == "dict":
                return "{}" if not node.args else f"pyDict({self.expr(node.args[0])})"
            if name == "set":
                return "pySet()" if not node.args else f"pySet({self.expr(node.args[0])})"
            if name == "divmod":
                return f"pyDivmod({self.expr(node.args[0])}, {self.expr(node.args[1])})"
            if name == "any" and node.args and isinstance(node.args[0], ast.GeneratorExp):
                return self.any_generator(node.args[0])
            if name == "sorted":
                return self.sorted_call(node)
            if name == "max":
                return self.extreme_call(node, "pyMax")
            if name == "min":
                return self.extreme_call(node, "pyMin")
            if name == "globals":
                return "__globals"

        if isinstance(node.func, ast.Attribute):
            attr = node.func.attr
            value = self.expr(node.func.value)
            if value == "random" and attr == "choice":
                return f"randomChoice({self.expr(node.args[0])})"
            if value == "random" and attr == "sample":
                return f"randomSample({self.expr(node.args[0])}, {self.expr(node.args[1])})"
            if value == "asyncio" and attr == "sleep":
                return f"sleep({self.expr(node.args[0])})"
            if attr == "items":
                return f"pyItems({value})"
            if attr == "get" and not self.is_daledou_get_receiver(node.func.value):
                default = self.expr(node.args[1]) if len(node.args) > 1 else "null"
                return f"pyGet({value}, {self.expr(node.args[0])}, {default})"
            if attr == "append":
                return f"{value}.push({self.expr(node.args[0])})"
            if attr == "extend":
                return f"{value}.push(...{self.expr(node.args[0])})"
            if attr == "add":
                return f"{value}.add({self.expr(node.args[0])})"
            if attr == "count":
                return f"pyCount({value}, {self.expr(node.args[0])})"
            if attr == "issubset":
                return f"pyIsSubset({value}, {self.expr(node.args[0])})"
            if attr == "endswith":
                return f"{value}.endsWith({self.expr(node.args[0])})"
            if attr == "startswith":
                return f"{value}.startsWith({self.expr(node.args[0])})"

        func = self.expr(node.func)
        args = ", ".join(self.expr(arg) for arg in node.args)
        if node.keywords:
            raise TranslationError(f"unsupported keyword call line {node.lineno}: {ast.unparse(node)}")
        return f"{func}({args})"

    def is_daledou_get_receiver(self, node: ast.AST) -> bool:
        if isinstance(node, ast.Name) and node.id == "d":
            return True
        if isinstance(node, ast.Attribute):
            if node.attr != "d":
                return False
            return isinstance(node.value, ast.Name) and node.value.id in {"self", "this"}
        return False

    def sorted_call(self, node: ast.Call) -> str:
        iterable = self.expr(node.args[0])
        key = "null"
        for keyword in node.keywords:
            if keyword.arg == "key":
                key = self.expr(keyword.value)
            else:
                raise TranslationError("unsupported sorted keyword")
        return f"pySorted({iterable}, {key})"

    def extreme_call(self, node: ast.Call, helper: str) -> str:
        iterable = self.expr(node.args[0])
        key = "null"
        for keyword in node.keywords:
            if keyword.arg == "key":
                key = self.expr(keyword.value)
            else:
                raise TranslationError(f"unsupported {helper} keyword")
        return f"{helper}({iterable}, {key})"

    def any_generator(self, node: ast.GeneratorExp) -> str:
        if len(node.generators) != 1:
            raise TranslationError("only simple generator expressions are supported")
        comp = node.generators[0]
        if comp.ifs:
            raise TranslationError("generator if clauses are not supported")
        target = self.for_target(comp.target)
        return f"pyAny({self.expr(comp.iter)}, ({target}) => {self.truthy_expr(node.elt)})"

    def generator_expr(self, node: ast.GeneratorExp) -> str:
        return self.any_generator(node)


def module_header(module: str, registered: list[str]) -> str:
    imports = ", ".join(RUNTIME_IMPORTS)
    lines = [f"import {{ {imports} }} from '../runtime.js';"]
    if module in {"noon", "evening"}:
        common_imports = ", ".join(COMMON_IMPORTS)
        lines.append(f"import {{ {common_imports} }} from './common.js';")
        lines.append("")
        lines.append(f"const registry = new Registry(TaskModule.{module});")
        lines.append("const register = (taskName, taskFunc) => registry.register(taskName, taskFunc);")
    lines.append("")
    return "\n".join(lines)


def module_footer(function_names: Iterable[str], registered: list[str]) -> str:
    names = list(function_names)
    exports = ", ".join(names)
    globals_map = ", ".join(f"{name}: {name}" for name in names)
    parts = ["", f"const __globals = {{ {globals_map} }};"]
    if exports:
        parts.append(f"export {{ {exports} }};")
    return "\n".join(parts) + "\n"


def translate_task_file(source: Path, target: Path, module: str) -> None:
    tree = ast.parse(source.read_text(encoding="utf-8"))
    writer = JsWriter(module)
    body, registered = writer.translate_module(tree)
    function_names = [
        node.name
        for node in tree.body
        if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef, ast.ClassDef))
    ]
    target.write_text(
        "// This file is generated by scripts/generate_cloudflare_worker_js.py.\n"
        "// Do not edit it by hand; edit src/tasks/*.py and regenerate.\n\n"
        + module_header(module, registered)
        + body
        + module_footer(function_names, registered),
        encoding="utf-8",
    )


def generate_config() -> None:
    data = yaml.safe_load((ROOT / "config" / "default.yaml").read_text(encoding="utf-8"))
    target = WORKER_SRC / "config.js"
    target.write_text(
        "// This file is generated by scripts/generate_cloudflare_worker_js.py.\n"
        "// Do not edit it by hand; edit config/default.yaml and regenerate.\n\n"
        f"export const DEFAULT_CONFIG = {json.dumps(data, ensure_ascii=False, indent=2)};\n",
        encoding="utf-8",
    )


def main() -> None:
    WORKER_TASKS_DIR.mkdir(parents=True, exist_ok=True)
    generate_config()
    translate_task_file(TASKS_DIR / "common.py", WORKER_TASKS_DIR / "common.js", "common")
    translate_task_file(TASKS_DIR / "noon.py", WORKER_TASKS_DIR / "noon.js", "noon")
    translate_task_file(TASKS_DIR / "evening.py", WORKER_TASKS_DIR / "evening.js", "evening")
    print("generated cloudflare_worker/src/config.js and task modules")


if __name__ == "__main__":
    main()
