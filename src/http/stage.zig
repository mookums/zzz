pub const Stage = union(enum) {
    header,
    body: u32,
};
