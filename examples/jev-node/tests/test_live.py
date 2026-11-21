"""Explicit opt-in API smoke test; synthetic context only, no graph delivery."""
import asyncio
import os

import httpx
import pytest

from common import Event, JudgeNode, Settings
from test_node import event_file


@pytest.mark.skipif(os.environ.get("JEV_LIVE_TEST") != "1", reason="Set JEV_LIVE_TEST=1 for paid synthetic API checks")
@pytest.mark.parametrize("custom", [False, True])
def test_live_decisions(tmp_path, custom):
    assert os.environ.get("OPENROUTER_API_KEY"), "OPENROUTER_API_KEY is required"
    event = Event.model_validate(event_file(tmp_path))
    config = {"question": "Does the last message explicitly say Approved?"}
    if custom:
        config.update(question="Classify the last message.",
                      options={"approved": "Explicit approval", "revise": "Requests changes"})
    async def run():
        async with httpx.AsyncClient(timeout=35) as client:
            # No host is needed: decide() only evaluates synthetic context.
            node = JudgeNode(Settings(**config), None, client)
            async with asyncio.timeout(45):
                output = await node.decide(event)
            assert output == ("approved" if custom else "True")
    asyncio.run(run())
