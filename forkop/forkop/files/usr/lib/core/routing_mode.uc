#!/usr/bin/env ucode
/**
 * Routing mode: economy/transport-only only (precise path removed).
 */

function is_economy() {
    return true;
}

function is_precise() {
    return false;
}

return {
    is_economy,
    is_precise
};
