import asyncio
import sys

from graffitty_graph_protocol import Manifest, Output, OutputPort, Session


async def main():
    async with Session() as node:
        await node.register(Manifest(name="Watcher", inputs=[], outputs=[OutputPort(id="done", line_style="solid")]))
        program = await asyncio.create_subprocess_exec(*sys.argv[1:], stdout=asyncio.subprocess.PIPE)
        output = asyncio.create_task(program.communicate())
        while not output.done():
            await node.heartbeat()
            await asyncio.sleep(1)
        if program.returncode == 0:
            text = (await output)[0].decode()
            await node.emit(Output(port="done", text=text))


if __name__ == "__main__":
    asyncio.run(main())
