import time

def main():
    count = 0
    while True:
        count += 1
        if count % 100 == 0:
            print(count)
            time.sleep(10)


if __name__ == "__main__":
    main()
