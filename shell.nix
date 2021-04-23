{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    cmake
    erlang
    gcc
    gmp
    gnumake
    rebar3
    openssl
  ];
}
