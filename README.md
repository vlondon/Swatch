# Swatch
Watcher for Unit Tests written in Swift

Command line program to watch project files changed and run unit tests against them.


## Usage

Change settings in `main.swift` agains your project.

```swift
let project = Project(path: "{path_to_project}", name: "{project_name}")
```

Run project from Xcode or command line

```sh
$ xcrun swift ./Swatch/main.swift 
```

To run unit tests in Xcode press:

`Cmd` + `Shift` + `e`

## Contributing

Contributions to Swatch are welcomed and encouraged! Feel free to fork the project and submit a pull request with your changes!


## Author

Vladimirs Matusevics, vladimir.matusevic@gmail.com, [Twitter](https://twitter.com/iGamesDev)
