from fastapi import FastAPI


def create_app() -> FastAPI:
    return FastAPI(
        title=__name__,
        version="0.1.0",
    )
