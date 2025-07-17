module joystiq::utils;

public(package) fun concat_bytes(a: &vector<u8>, b: &vector<u8>): vector<u8> {
    let mut result = vector::empty<u8>();
    let mut i = 0;
    while (i < vector::length(a)) {
        vector::push_back(&mut result, *vector::borrow(a, i));
        i = i + 1;
    };
    let mut j = 0;
    while (j < vector::length(b)) {
        vector::push_back(&mut result, *vector::borrow(b, j));
        j = j + 1;
    };
    result
}

public(package) fun bytes_less_than(a: &vector<u8>, b: &vector<u8>): bool {
    let len_a = vector::length(a);
    let len_b = vector::length(b);
    let min_len = if (len_a < len_b) { len_a } else { len_b };

    let mut i = 0;
    while (i < min_len) {
        let byte_a = *vector::borrow(a, i);
        let byte_b = *vector::borrow(b, i);
        if (byte_a < byte_b) return true;
        if (byte_a > byte_b) return false;
        i = i + 1;
    };

    // If equal up to min_len, shorter vector is "less"
    len_a < len_b
}
