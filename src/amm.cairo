from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.dict import dict_read, dict_write
from starkware.cairo.common.math import assert_nn_le
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.dict import dict_update

const MAX_BALANCE = 2 ** 64 - 1


struct Account:
    member public_key : felt
    member token_a_balance : felt
    member token_b_balance : felt
end

struct AmmState:
    # A dictionary that tracks the accounts' state.
    member account_dict_start : DictAccess*
    member account_dict_end : DictAccess*
    # The amount of the tokens currently in the AMM.
    # Must be in the range [0, MAX_BALANCE].
    member token_a_balance : felt
    member token_b_balance : felt 
end
struct SwapTransactionA:
    member account_id : felt
    member token_a_amount : felt
end

struct SwapTransactionB:
    member account_id : felt
    member token_b_amount : felt
end

func modify_account{range_check_ptr}(
    state : AmmState, account_id : felt, diff_a : felt, diff_b : felt
) -> (state : AmmState, key : felt):
    alloc_locals

    let account_dict_end = state.account_dict_end

    let (local old_account : Account*) = dict_read{dict_ptr=account_dict_end}(
        key=account_id
    )

    tempvar new_value_a = old_account.token_a_balance + diff_a
    tempvar new_value_b = old_account.token_b_balance + diff_b

    assert_nn_le(new_value_a, MAX_BALANCE)
    assert_nn_le(new_value_b, MAX_BALANCE)

    local new_account : Account
    assert new_account.public_key = old_account.public_key
    assert new_account.token_a_balance = new_value_a
    assert new_account.token_b_balance = new_value_b

    let (__fp__, _) = get_fp_and_pc()
    dict_write{dict_ptr=account_dict_end}(
        key=account_id, new_value=cast(&new_account, felt)
    )

    local new_state : AmmState
    assert new_state.account_dict_start = state.account_dict_start
    assert new_state.account_dict_end = account_dict_end
    assert new_state.token_a_balance = state.token_a_balance
    assert new_state.token_b_balance = state.token_b_balance

    return (state=new_state, key=old_account.public_key)

end

func swap_to_get_token_b{range_check_ptr}(
    state : AmmState, transaction : SwapTransactionA*
) -> (state : AmmState):
    alloc_locals
    tempvar x = state.token_a_balance
    tempvar y = state.token_b_balance
    tempvar a = transaction.token_a_amount
    assert_nn_le(a, MAX_BALANCE)

    let (amount_b, _) = unsigned_div_rem(y * a, x + a)
    assert_nn_le(amount_b, MAX_BALANCE)

    let (state, key) = modify_account(state, transaction.account_id, -a, amount_b )
    return (state=state)
end

func swap_to_get_token_a{range_check_ptr}(
    state : AmmState, transaction : SwapTransactionB*
) -> (state : AmmState):
    alloc_locals
    tempvar x = state.token_a_balance
    tempvar y = state.token_b_balance
    tempvar b = transaction.token_b_amount
    assert_nn_le(b, MAX_BALANCE)

    let (amount_a, _) = unsigned_div_rem(x * b, y - b)
    assert_nn_le(amount_a, MAX_BALANCE)

    let (state, key) = modify_account(state, transaction.account_id, amount_a, -b )
    return (state=state)
end

func transaction_b_loop{range_check_ptr}(
    state : AmmState, transactions : SwapTransactionA**, n_transactions : felt
) -> (state : AmmState):
    if n_transactions == 0:
        return (state=state)
    end
    let transaction : SwapTransactionA* = [transactions]
    let (state) = swap_to_get_token_b(state=state, transaction=transaction)

    return transaction_b_loop(state=state,transactions=transactions + 1, n_transactions=n_transactions - 1)
end

func transaction_a_loop{range_check_ptr}(
    state : AmmState, transactions : SwapTransactionB**, n_transactions : felt
) -> (state : AmmState):
    if n_transactions == 0:
        return (state=state)
    end
    let transaction : SwapTransactionB* = [transactions]
    let (state) = swap_to_get_token_a(state=state, transaction=transaction)

    return transaction_a_loop(state=state,transactions=transactions + 1, n_transactions=n_transactions - 1)
end

func hash_account{pedersen_ptr : HashBuiltin*}(
    account : Account*
) -> (res : felt):
    let res = account.public_key
    let (res) = hash2{hash_ptr=pedersen_ptr}(
        res, account.token_a_balance
    )
      let (res) = hash2{hash_ptr=pedersen_ptr}(
        res, account.token_b_balance
    )
    return (res=res)
end

func hash_dict_values{pedersen_ptr : HashBuiltin*}(
    dict_start : DictAccess*,
    dict_end : DictAccess*,
    hash_dict_start : DictAccess*
) -> (hash_dict_end : DictAccess*):
    if dict_start == dict_end:
        return (hash_dict_end=hash_dict_start)        
    end
    let (prev_hash) = hash_account(
        account=cast(dict_start.prev_value, Account*)
    )
    let (new_hash) = hash_account(
        account=cast(dict_start.new_value, Account*)
    )

    dict_update{dict_ptr=hash_dict_start}(
        key=dict_start.key,
        prev_value=prev_hash,
        new_value=new_hash
    )

    return hash_dict_values(
                dict_start=dict_start + DictAccess.SIZE,
                dict_end=dict_end,
                hash_dict_start=hash_dict_start
           )

end