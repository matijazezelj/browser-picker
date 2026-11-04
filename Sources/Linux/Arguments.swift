// Browser Picker (Linux) -- the arguments of --open, which the desktop file
// and scripts use. Pure, so the tests can try every arrangement.

/// The link text and the --target value of `--open URL` or
/// `--target REF --open URL` (in either order); nil for anything else.
func openArguments(_ args: [String]) -> (text: String, target: String?)? {
    switch args.count {
    case 2 where args[0] == "--open":
        return (args[1], nil)
    case 4 where args[0] == "--open" && args[2] == "--target":
        return (args[1], args[3])
    case 4 where args[0] == "--target" && args[2] == "--open":
        return (args[3], args[1])
    default:
        return nil
    }
}
