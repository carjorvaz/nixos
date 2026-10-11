#!/usr/bin/env python3
"""CPU-only tests of exact boundary selection and real allocator/hash metadata."""
from types import SimpleNamespace as NS
import torch
from vllm.v1.core.sched.scheduler import Scheduler
from vllm.v1.core.kv_cache_coordinator import HybridKVCacheCoordinator
from vllm.v1.core.block_pool import BlockPool
from vllm.v1.core.single_type_kv_cache_manager import MambaManager
from vllm.v1.kv_cache_interface import FullAttentionSpec, MambaSpec, KVCacheConfig, KVCacheGroupSpec

BLOCK, HASH = 1632, 16
full = FullAttentionSpec(block_size=BLOCK,num_kv_heads=4,head_size=256,dtype=torch.float16)
mamba = MambaSpec(block_size=BLOCK,shapes=((128,128),),dtypes=(torch.float16,),mamba_cache_mode='align',num_speculative_blocks=4)

def coordinator():
    config=KVCacheConfig(num_blocks=256,kv_cache_tensors=[],kv_cache_groups=[KVCacheGroupSpec(['full'],full),KVCacheGroupSpec(['mamba'],mamba),KVCacheGroupSpec(['draft'],full,is_eagle_group=True)])
    return HybridKVCacheCoordinator(config,262144,8,True,True,False,1,1,BLOCK,HASH,num_prefill_lookahead=4)

for prompt in [1,15,16,17,31,32,33,1632,1633,1648,32640,32641,32656,32768,32769,32783]:
    sched=NS(cache_config=NS(block_size=BLOCK),block_size=BLOCK,hash_block_size=HASH,use_eagle=True,
         # 0.31 keys the Mamba checkpoint shift (and the manager's matching
         # gate) on the block-drop bit, not plain use_eagle.
         use_eagle_block_drop=True,
         # Internal Mamba prefill checkpoint blocks are disabled under
         # Eagle/MTP, which is the configuration this check exercises.
         mamba_has_prefill_checkpoint_blocks=False,mamba_partial_cache_hit=True,max_num_scheduled_tokens=2048,scheduler_config=NS(long_prefill_token_threshold=0),num_prefill_lookahead=4)
    request=NS(num_computed_tokens=0,num_prompt_tokens=prompt,num_tokens=prompt,shared_prefix_boundary=0)
    stops=[]
    while request.num_computed_tokens<prompt:
        length=Scheduler._mamba_block_aligned_split(sched,request,min(2048,prompt-request.num_computed_tokens))
        length=Scheduler._reserve_prefill_lookahead(sched,request,request.num_computed_tokens,length)
        assert length>0,(prompt,request.num_computed_tokens)
        request.num_computed_tokens+=length
        stops.append(request.num_computed_tokens)
    checkpoint=max(0,prompt//HASH*HASH-HASH)
    if checkpoint>0 and not 0<prompt%BLOCK<4:
        assert checkpoint in stops,(prompt,checkpoint,stops)
    print('PASS scheduler',prompt,checkpoint,flush=True)

for prompt in [32640,32641,32656,32768,32769,32783]:
    c=coordinator(); pool=c.block_pool
    boundary=prompt//HASH*HASH
    checkpoint=(prompt//BLOCK-1)*BLOCK if 0<prompt%BLOCK<4 else boundary-HASH
    request=NS(request_id='test',num_prompt_tokens=prompt,block_hashes=[i.to_bytes(16,'little') for i in range(1,2200)])
    for gid in (0,2):
        manager=c.single_type_managers[gid]
        blocks=pool.get_new_blocks((prompt+BLOCK-1)//BLOCK)
        manager.req_to_blocks['test']=blocks
        pool.cache_full_blocks(request,blocks,0,boundary//BLOCK,BLOCK,gid)
        manager._cache_partial_tail_block(request,prompt)
    manager=c.single_type_managers[1]
    idx=checkpoint//BLOCK
    if checkpoint%BLOCK:
        blocks=[pool.null_block]*idx+pool.get_new_blocks(1+4)
        manager.req_to_blocks['test']=blocks
        source=blocks[idx]
        manager._allocated_block_reqs.add('test')
        key=manager._cache_partial_tail_block(request,checkpoint,retention_interval=None)
        assert key is not None
        assert manager._cache_partial_tail_block(request,boundary,retention_interval=None) is None
        assert pool.get_cached_block(request.block_hashes[checkpoint//HASH-1],[1])==[source]
        # Running producer CoW: preserve checkpoint while its original slot advances.
        manager.allocate_new_blocks('test',checkpoint+8+4,checkpoint+8)
        copied=pool.get_cached_block(request.block_hashes[checkpoint//HASH-1],[1])[0]
        assert copied is not source and source.block_hash is None
        assert (source,copied) in manager._pending_cow_copies
    else:
        blocks=[pool.null_block]*(idx-1)+pool.get_new_blocks(1)
        pool.cache_full_blocks(request,blocks,idx-1,idx,BLOCK,1)
    hit,length,_=c.find_longest_cache_hit(request.block_hashes,prompt+64)
    assert length==checkpoint,(prompt,checkpoint,length)
    assert len(hit[0])==(checkpoint+BLOCK-1)//BLOCK
    # No matching hash means no state may be reused by an unrelated prefix.
    _,length,_=c.find_longest_cache_hit([b'x'+h for h in request.block_hashes],prompt+64)
    assert length==0
    print('PASS allocator+lookup+COW',prompt,checkpoint,flush=True)
print('CACHE_CPU_REGRESSION_PASS',flush=True)

for hash_size, lookahead in [(1,0),(1,1),(2,2),(4,4),(8,3),(16,4),(32,8)]:
    for prompt in range(1, 2*BLOCK+hash_size+1):
        sched=NS(cache_config=NS(block_size=BLOCK),block_size=BLOCK,hash_block_size=hash_size,use_eagle=bool(lookahead),
                 use_eagle_block_drop=bool(lookahead),
                 # The spec below leaves num_prefill_checkpoint_blocks at 0, so
                 # internal Mamba prefill checkpoints stay off here.
                 mamba_has_prefill_checkpoint_blocks=False,mamba_partial_cache_hit=True,max_num_scheduled_tokens=2048,scheduler_config=NS(long_prefill_token_threshold=0),num_prefill_lookahead=lookahead)
        request=NS(num_computed_tokens=0,num_prompt_tokens=prompt,num_tokens=prompt,shared_prefix_boundary=0)
        stops=[]
        while request.num_computed_tokens<prompt:
            length=Scheduler._mamba_block_aligned_split(sched,request,min(2048,prompt-request.num_computed_tokens))
            length=Scheduler._reserve_prefill_lookahead(sched,request,request.num_computed_tokens,length)
            assert length>0,(hash_size,lookahead,prompt,stops)
            request.num_computed_tokens+=length;stops.append(request.num_computed_tokens)
            assert len(stops)<10
        checkpoint=max(0,prompt//hash_size*hash_size-(hash_size if lookahead else 0))
        if checkpoint>0 and not 0<prompt%BLOCK<lookahead:
            assert checkpoint in stops,(hash_size,lookahead,prompt,checkpoint,stops)
    print('PASS exhaustive boundaries',hash_size,lookahead,flush=True)
for invalid_hash in (1,2,3):
    config=KVCacheConfig(num_blocks=256,kv_cache_tensors=[],kv_cache_groups=[KVCacheGroupSpec(['full'],full),KVCacheGroupSpec(['mamba'],mamba),KVCacheGroupSpec(['draft'],full,is_eagle_group=True)])
    try: HybridKVCacheCoordinator(config,262144,8,True,True,False,1,1,BLOCK,invalid_hash,num_prefill_lookahead=4)
    except ValueError as e: assert 'hash_block_size' in str(e)
    else: raise AssertionError('unsafe fine-hash lookahead accepted')

# Exercise the real align-mode manager and pool across the sparse null gaps
# produced by chunked prefill.  The eligible prefix must be retired even when
# its newest slot is null, while the speculative/live tail remains bounded.
retirement = coordinator()
retirement_manager = retirement.single_type_managers[1]
retirement_pool = retirement.block_pool
retirement_request = "retirement"
free_before = retirement_pool.get_num_free_blocks()
physical_positions = list(range(0, 72, 8)) + list(range(72, 77))
physical_blocks = retirement_pool.get_new_blocks(len(physical_positions))
physical_by_position = dict(zip(physical_positions, physical_blocks))
retirement_manager.req_to_blocks[retirement_request] = [
    physical_by_position.get(i, retirement_pool.null_block) for i in range(77)
]
retirement_manager.remove_skipped_blocks(retirement_request, 72 * BLOCK + 1)
live_positions = [
    i
    for i, block in enumerate(retirement_manager.req_to_blocks[retirement_request])
    if not block.is_null
]
assert live_positions == list(range(72, 77)), live_positions
assert retirement_pool.get_num_free_blocks() == free_before - 5
assert retirement_manager._num_retired_blocks[retirement_request] == 72

# Repeating or widening a completed retirement range cannot free a block twice.
free_after_retirement = retirement_pool.get_num_free_blocks()
retirement_manager.remove_skipped_blocks(retirement_request, 72 * BLOCK + 1)
assert retirement_pool.get_num_free_blocks() == free_after_retirement

# Request teardown clears the retirement cursor, so reusing an ID starts a new
# lifecycle rather than skipping newly allocated state.
remaining = retirement_manager.pop_blocks_for_free(retirement_request)
assert retirement_request not in retirement_manager._num_retired_blocks
retirement_pool.free_blocks(block for block in remaining if not block.is_null)
assert retirement_pool.get_num_free_blocks() == free_before
new_state = retirement_pool.get_new_blocks(1)[0]
retirement_manager.req_to_blocks[retirement_request] = [new_state]
retirement_manager._remove_blocks_in_range(retirement_request, 0, 1)
assert retirement_pool.get_num_free_blocks() == free_before
assert retirement_manager._num_retired_blocks[retirement_request] == 1
retirement_manager.pop_blocks_for_free(retirement_request)

# Non-align Mamba retains the base remover's contiguous-tail semantics.
plain_pool = BlockPool(16, True, BLOCK)
plain_spec = MambaSpec(
    block_size=BLOCK,
    shapes=((128, 128),),
    dtypes=(torch.float16,),
    mamba_cache_mode="all",
    num_speculative_blocks=4,
)
plain_manager = MambaManager(
    plain_spec,
    plain_pool,
    enable_caching=True,
    kv_cache_group_id=0,
    scheduler_block_size=BLOCK,
)
plain_free_before = plain_pool.get_num_free_blocks()
left, right = plain_pool.get_new_blocks(2)
plain_manager.req_to_blocks["plain"] = [left, plain_pool.null_block, right]
plain_manager._remove_blocks_in_range("plain", 0, 3)
assert plain_manager.req_to_blocks["plain"] == [
    left,
    plain_pool.null_block,
    plain_pool.null_block,
]
assert plain_pool.get_num_free_blocks() == plain_free_before - 1
plain_pool.free_blocks([left])
plain_manager.pop_blocks_for_free("plain")
assert plain_pool.get_num_free_blocks() == plain_free_before
assert not hasattr(plain_manager, "_num_retired_blocks")
print("MAMBA_RETIREMENT_REGRESSION_PASS", flush=True)
print('TURING_PREFIX_REGRESSION_PASS',flush=True)
