FROM redhat/ubi9:latest

RUN dnf install -y openssh-server python3 && \
    dnf clean all && \
    ssh-keygen -A

RUN echo 'root:ansible' | chpasswd

RUN sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
